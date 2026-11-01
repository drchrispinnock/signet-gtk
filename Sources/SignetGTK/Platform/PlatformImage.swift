import CAdwaita
import CWebP
import Foundation

/// A decoded image, standing in for `NSImage` in `ImageLoader` and `ArtworkCache`: a GdkTexture,
/// which is immutable and may be made and passed on any thread, then drawn by a `GtkPicture`.
final class PlatformImage: @unchecked Sendable {
    let texture: OpaquePointer   // GdkTexture
    let width: Int
    let height: Int

    init(texture: OpaquePointer) {
        self.texture = texture
        width = Int(gdk_texture_get_width(texture))
        height = Int(gdk_texture_get_height(texture))
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(texture)) }

    /// Decodes `data` (WebP through libwebp, anything else gdk-pixbuf has a loader for, SVG
    /// through librsvg), scaled while decoding so its long edge is at most `maxPixelSize`; an
    /// image that declares an edge longer than `refusingAbove` is not decoded at all.
    static func decode(_ data: Data, maxPixelSize: Int, refusingAbove: Int? = nil) -> PlatformImage? {
        if isWebP(data) { return decodeWebP(data, maxPixelSize: maxPixelSize, refusingAbove: refusingAbove) }
        final class Sizing {
            let maxPixelSize: Int
            let refusingAbove: Int?
            var refused = false
            init(_ maxPixelSize: Int, _ refusingAbove: Int?) { self.maxPixelSize = maxPixelSize; self.refusingAbove = refusingAbove }
        }
        guard !data.isEmpty, let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
        let sizing = Sizing(max(1, maxPixelSize), refusingAbove)
        let prepared: @convention(c) (UnsafeMutablePointer<GdkPixbufLoader>?, Int32, Int32, gpointer?) -> Void = { loader, width, height, data in
            let sizing = Unmanaged<Sizing>.fromOpaque(data!).takeUnretainedValue()
            let long = Int(max(width, height))
            if let limit = sizing.refusingAbove, long > limit || width <= 0 || height <= 0 {
                sizing.refused = true
                gdk_pixbuf_loader_set_size(loader, 1, 1)
                return
            }
            guard long > sizing.maxPixelSize else { return }
            let scale = Double(sizing.maxPixelSize) / Double(long)
            gdk_pixbuf_loader_set_size(loader, max(1, Int32(Double(width) * scale)), max(1, Int32(Double(height) * scale)))
        }
        let unmanaged = Unmanaged.passRetained(sizing)
        defer { unmanaged.release() }
        g_signal_connect_data(UnsafeMutableRawPointer(loader), "size-prepared", unsafeBitCast(prepared, to: GCallback.self), unmanaged.toOpaque(), nil, GConnectFlags(rawValue: 0))

        var error: UnsafeMutablePointer<GError>?
        let written = data.withUnsafeBytes { bytes in
            gdk_pixbuf_loader_write(loader, bytes.bindMemory(to: guchar.self).baseAddress, gsize(bytes.count), &error)
        }
        var closeError: UnsafeMutablePointer<GError>?
        let closed = gdk_pixbuf_loader_close(loader, &closeError)
        if let error { g_error_free(error) }
        if let closeError { g_error_free(closeError) }
        guard written != 0, closed != 0, !sizing.refused, let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        guard let texture = gdk_texture_new_for_pixbuf(pixbuf) else { return nil }
        return PlatformImage(texture: texture)
    }

    private static func isWebP(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4).elementsEqual("RIFF".utf8) && data.dropFirst(8).prefix(4).elementsEqual("WEBP".utf8)
    }

    /// The first frame of a WebP image, scaled as `decode` does.
    private static func decodeWebP(_ data: Data, maxPixelSize: Int, refusingAbove: Int?) -> PlatformImage? {
        var config = WebPDecoderConfig()
        guard WebPInitDecoderConfig(&config) != 0 else { return nil }
        return data.withUnsafeBytes { raw -> PlatformImage? in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            guard WebPGetFeatures(bytes, raw.count, &config.input) == VP8_STATUS_OK else { return nil }
            let width = Int(config.input.width), height = Int(config.input.height)
            let long = max(width, height)
            guard width > 0, height > 0 else { return nil }
            if let refusingAbove, long > refusingAbove { return nil }
            if long > max(1, maxPixelSize) {
                let scale = Double(maxPixelSize) / Double(long)
                config.options.use_scaling = 1
                config.options.scaled_width = Int32(max(1, Double(width) * scale))
                config.options.scaled_height = Int32(max(1, Double(height) * scale))
            }
            config.output.colorspace = MODE_RGBA
            guard WebPDecode(bytes, raw.count, &config) == VP8_STATUS_OK else { return nil }
            defer { WebPFreeDecBuffer(&config.output) }
            let rgba = config.output.u.RGBA
            guard let pixels = g_bytes_new(rgba.rgba, gsize(rgba.size)) else { return nil }
            defer { g_bytes_unref(pixels) }
            guard let texture = gdk_memory_texture_new(config.output.width, config.output.height, GDK_MEMORY_R8G8B8A8, pixels, gsize(rgba.stride)) else { return nil }
            return PlatformImage(texture: texture)
        }
    }

    /// The image as PNG.
    func png() -> Data? {
        guard let bytes = gdk_texture_save_to_png_bytes(texture) else { return nil }
        defer { g_bytes_unref(bytes) }
        var size: gsize = 0
        guard let pointer = g_bytes_get_data(bytes, &size) else { return nil }
        return Data(bytes: pointer, count: Int(size))
    }
}
