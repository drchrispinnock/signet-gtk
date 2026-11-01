import Crypto
import Foundation

/// Thumbnails kept on disk between launches, already downsampled, so an account's artwork is
/// fetched from the gateways once rather than on every launch and account switch.
///
/// IPFS content is named by its CID, so an entry keyed by the content path never goes stale
/// and answers for every gateway's URL of that content; artwork at any other HTTPS URL can
/// change behind the URL, so those entries expire after `mutableLifetime`. Content a gateway
/// reported too large (`ImageLoader.Fetch.tooLarge`) is remembered as well, so it is skipped
/// without a request next time. Entries are PNGs written with `PrivateFile` (0600 files under
/// a 0700 folder, atomic replacement), the folder is capped at `maxBytes` with the oldest
/// entries removed first, and nothing here is ever a secret: the folder is
/// `~/Library/Caches/Signet/artwork`, outside the wallet directory and its backups.
///
/// The Linux counterpart of upstream's `Signet/Services/ArtworkCache.swift`, in the same order
/// with the same names. The differences: images are `PlatformImage` (see `ImageLoader`), and the
/// folder is `$XDG_CACHE_HOME/signet/artwork` (`~/.cache` by default).
struct ArtworkCache: Equatable, Sendable {
    let directory: URL
    /// The folder's size cap; pruning brings it down to four fifths of this.
    var maxBytes = 256 << 20
    /// How long an entry for a mutable (non-IPFS) URL is served.
    var mutableLifetime: TimeInterval = 7 * 24 * 3600
    /// How long "too large" is remembered; the cap could change with a release.
    var tooLargeLifetime: TimeInterval = 30 * 24 * 3600
    /// The largest decoded image worth writing (an SVG can declare any size).
    static let maxStoredPixels = 2048 * 2048

    /// The production cache, or `nil` under the test host (S24: the app under test touches
    /// no real paths).
    static let standard: ArtworkCache? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return ArtworkCache(directory: caches.appendingPathComponent("signet/artwork", isDirectory: true))
    }()

    /// What an entry is keyed on.
    enum Key: Equatable, Sendable {
        /// IPFS content, by its `<cid>[/path]`: the same on every gateway, and immutable.
        case content(String)
        /// Anything else, by the exact URL.
        case url(String)

        var isImmutable: Bool { if case .content = self { true } else { false } }
        fileprivate var text: String {
            switch self {
            case .content(let path): "ipfs:" + path
            case .url(let url): "url:" + url
            }
        }
    }

    static func key(for url: URL) -> Key {
        if let path = IPFS.gatewayContentPath(of: url) { return .content(path.encoded) }
        return .url(url.absoluteString)
    }

    // MARK: Entries

    /// The cached thumbnail for `url` at `maxPixelSize`, if there is a live one.
    func image(for url: URL, maxPixelSize: Int) -> PlatformImage? {
        let key = Self.key(for: url)
        let file = imageFile(for: key, maxPixelSize: maxPixelSize)
        guard isLive(file, lifetime: key.isImmutable ? nil : mutableLifetime), let data = try? PrivateFile.read(file) else { return nil }
        return ImageLoader.downsample(data, maxPixelSize: maxPixelSize)
    }

    /// Writes `image` as the thumbnail for `url` at `maxPixelSize`. Failures are silent: the
    /// cache is a convenience and the image is already on screen.
    func store(_ image: PlatformImage, for url: URL, maxPixelSize: Int) {
        guard let png = Self.png(image) else { return }
        try? PrivateFile.write(png, to: imageFile(for: Self.key(for: url), maxPixelSize: maxPixelSize))
    }

    /// Whether `url`'s content was reported too large recently enough to still skip it.
    func isTooLarge(_ url: URL) -> Bool {
        isLive(tooLargeFile(for: Self.key(for: url)), lifetime: tooLargeLifetime)
    }

    func markTooLarge(_ url: URL) {
        try? PrivateFile.write(Data(), to: tooLargeFile(for: Self.key(for: url)))
    }

    /// Removes expired entries, leftover temporaries and then, while the folder is over
    /// `maxBytes`, the oldest entries. Cheap enough to run once per launch.
    func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var live: [(url: URL, size: Int, modified: Date)] = []
        for name in names {
            let file = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let size = attributes[.size] as? Int ?? 0
            let lifetime: TimeInterval?
            if name.hasSuffix(PrivateFile.temporarySuffix) { lifetime = 3600 }
            else if name.hasPrefix(Self.tooLargePrefix) { lifetime = tooLargeLifetime }
            else if name.hasPrefix(Self.mutablePrefix) { lifetime = mutableLifetime }
            else if name.hasPrefix(Self.immutablePrefix) { lifetime = nil }
            else { continue }
            if let lifetime, Date().timeIntervalSince(modified) > lifetime {
                try? fm.removeItem(at: file)
            } else {
                live.append((file, size, modified))
            }
        }
        var total = live.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        for entry in live.sorted(by: { $0.modified < $1.modified }) where total > maxBytes * 4 / 5 {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Files

    private static let immutablePrefix = "i-"
    private static let mutablePrefix = "u-"
    private static let tooLargePrefix = "x-"

    private func imageFile(for key: Key, maxPixelSize: Int) -> URL {
        let prefix = key.isImmutable ? Self.immutablePrefix : Self.mutablePrefix
        return directory.appendingPathComponent(prefix + Self.digest(key.text + "|\(maxPixelSize)") + ".png")
    }

    private func tooLargeFile(for key: Key) -> URL {
        directory.appendingPathComponent(Self.tooLargePrefix + Self.digest(key.text))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A regular file that exists and, given a lifetime, is younger than it.
    private func isLive(_ file: URL, lifetime: TimeInterval?) -> Bool {
        // `attributesOfItem` reads with lstat, so a symlink is not a regular file; it also spares
        // naming `stat`'s time field, which the BSDs and Linux spell differently.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        guard let lifetime else { return true }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return Date().timeIntervalSince(modified) <= lifetime
    }

    /// The image as PNG, the format every decoded thumbnail (and a rendered SVG) round-trips through.
    static func png(_ image: PlatformImage) -> Data? {
        guard image.width * image.height <= maxStoredPixels else { return nil }
        return image.png()
    }
}
