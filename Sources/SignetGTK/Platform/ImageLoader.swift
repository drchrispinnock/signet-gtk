import CAdwaita
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads an image from the first URL that works and downsamples it for display.
/// Decoded images are cached in memory, and the production loader keeps the downsampled
/// thumbnails on disk too (`ArtworkCache`), so artwork is fetched once, not on every launch.
///
/// Artwork URLs come from token metadata, so they are untrusted (S13): only public HTTPS
/// destinations are contacted (checked by name and again after DNS resolution), redirects
/// may only lead to other public HTTPS destinations, the response must be an image, and the
/// download is cut off at `maxBytes` while it streams. At most `maxConcurrent` loads run at once.
///
/// The Linux counterpart of upstream's `Signet/Services/ImageLoader.swift`, in the same order
/// with the same names. The difference: images are `PlatformImage` (a GdkTexture) in place of
/// `PlatformImage`, decoded and downsampled by gdk-pixbuf (whose SVG loader is librsvg) in place of
/// ImageIO.
actor ImageLoader {
    static let shared = ImageLoader(disk: ArtworkCache.standard)

    /// The most a single artwork may download; a thumbnail never needs more.
    static let maxBytes = 8 << 20
    static let maxConcurrent = 6

    /// What one download attempt came to.
    enum Fetch: Sendable {
        case data(Data)
        /// The content is larger than `maxBytes`: it will be on every gateway, so the other
        /// URLs naming the same IPFS content are not worth a request.
        case tooLarge
        /// Refused, unreachable, rate-limited or not an image: the next URL may still work.
        case unavailable
    }

    private let cache = NSCache<NSString, PlatformImage>()
    private let disk: ArtworkCache?
    private var pruned = false
    private let fetcher: @Sendable (URL) async -> Fetch
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// A loader with no disk cache (tests, previews) unless `disk` is given.
    init(disk: ArtworkCache? = nil, fetch: (@Sendable (URL) async -> Fetch)? = nil) {
        self.disk = disk
        fetcher = fetch ?? { await ImageLoader.fetch($0) }
        cache.countLimit = 300
        cache.totalCostLimit = 96 << 20
    }

    /// A loader whose downloads are answered by `download` (`nil` is `unavailable`); for tests.
    init(download: @escaping @Sendable (URL) async -> Data?) {
        self.init(fetch: { url in
            if let data = await download(url) { .data(data) } else { .unavailable }
        })
    }

    /// Tries `candidates` in order; returns the first that yields a decodable image. The
    /// candidates are a token's images best first, one URL per gateway for each (display
    /// render, then thumbnail, then artifact): when a gateway says the content is too large,
    /// every other gateway's copy of that content is skipped and the next image is tried.
    /// The disk cache is consulted in that same order, candidate by candidate, so a cached
    /// lesser image never stands in for a better one that was never fetched: marketplaces
    /// give many tokens one generic thumbnail, and once it is on disk it must not become
    /// every such token's tile.
    func image(for candidates: [URL], maxPixelSize: Int = 400) async -> PlatformImage? {
        guard let key = candidates.first?.absoluteString else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }

        guard inFlight.count < 128, candidates.count <= 16 else { return nil }
        let maxPixelSize = min(max(1, maxPixelSize), 2048)
        let task = Task<PlatformImage?, Never> {
            await self.acquireSlot()
            defer { self.releaseSlot() }
            var tooLarge: [IPFS.ContentPath] = []
            for url in candidates {
                guard !Task.isCancelled else { return nil }
                guard EndpointPolicy.isPublicHTTPS(url) else { continue }
                // This image already on disk, from whichever gateway, needs no request.
                if let disk = self.disk, let image = disk.image(for: url, maxPixelSize: maxPixelSize) { return image }
                let content = IPFS.gatewayContentPath(of: url)
                if let content, tooLarge.contains(content) { continue }
                if let disk = self.disk, disk.isTooLarge(url) { continue }
                switch await fetcher(url) {
                case .data(let data):
                    if let image = Self.downsample(data, maxPixelSize: maxPixelSize) {
                        self.store(image, for: url, maxPixelSize: maxPixelSize)
                        return image
                    }
                case .tooLarge:
                    if let content { tooLarge.append(content) }
                    self.disk?.markTooLarge(url)
                case .unavailable:
                    continue
                }
            }
            return nil
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image)) }
        return image
    }

    /// Writes a fetched thumbnail to the disk cache, pruning the folder first once per process.
    private func store(_ image: PlatformImage, for url: URL, maxPixelSize: Int) {
        guard let disk else { return }
        if !pruned { pruned = true; disk.prune() }
        disk.store(image, for: url, maxPixelSize: maxPixelSize)
    }

    /// Bytes an image roughly occupies once decoded, for the cache's cost limit.
    nonisolated static func cost(of image: PlatformImage) -> Int {
        max(1, image.width * image.height * 4)
    }

    private func acquireSlot() async {
        if active < Self.maxConcurrent { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
        else { active -= 1 }
    }

    // MARK: Bounded download

    /// Is this response worth reading? 2xx, an image (or SVG) and not declared larger than the limit.
    nonisolated static func acceptsResponse(status: Int, contentType: String?, contentLength: Int64?, maxBytes: Int = ImageLoader.maxBytes) -> Bool {
        guard (200..<300).contains(status) else { return false }
        if let contentLength, contentLength > Int64(maxBytes) { return false }
        let type = (contentType ?? "").lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        // Gateways sometimes serve artwork as octet-stream; the decoder is the final judge then.
        return type.hasPrefix("image/") || type == "application/octet-stream" || type == "application/xml" || type == "text/xml" || type.isEmpty
    }

    /// Downloads `url` through the pinned public client; `unavailable` on any refusal or
    /// failure, `tooLarge` when the content passes `maxBytes` (curl stops at the declared
    /// length before a byte of the body, or while it streams).
    private static func fetch(_ url: URL) async -> Fetch {
        do {
            let reply = try await PublicHTTPClient.data(for: URLRequest(url: url), limit: maxBytes, followRedirects: true)
            guard acceptsResponse(status: reply.status, contentType: reply.headers["content-type"], contentLength: Int64(reply.data.count)) else { return .unavailable }
            return .data(reply.data)
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            return .tooLarge
        } catch { return .unavailable }
    }

    /// Decodes at most `maxPixelSize` on the long edge so a grid of large artworks stays cheap.
    /// gdk-pixbuf scales while it decodes, SVG included (its loader is librsvg).
    nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> PlatformImage? {
        guard data.count <= maxBytes else { return nil }
        if isSVGHead(data) { return PlatformImage.decode(data, maxPixelSize: maxPixelSize, refusingAbove: 16384) }
        return PlatformImage.decode(data, maxPixelSize: maxPixelSize)
    }

    /// An SVG document as an image at its own size, or `nil` if the data is not one or
    /// declares an absurd size.
    nonisolated static func svg(_ data: Data) -> PlatformImage? {
        guard isSVGHead(data) else { return nil }
        return PlatformImage.decode(data, maxPixelSize: 16384, refusingAbove: 16384)
    }

    private nonisolated static func isSVGHead(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg") || head.contains("<?xml")
    }
}
