import CAdwaita
import Foundation

/// Scan QR code's camera and decoder: upstream's `Services/QRScanner.swift` with zbar in place of
/// AVFoundation and Vision. libzbar is opened at run time (`ZBar`), so Signet starts without it
/// and only Scan QR code goes; cameras are the V4L2 capture devices in `/dev` (Linux, and the
/// BSDs through webcamd), read through zbar's own video module.

/// A camera the scanner can use.
struct CameraDevice: Identifiable, Hashable, Sendable {
    /// The device node, `/dev/video0`.
    let id: String
    let name: String
}

enum QRCamera {
    /// The video capture devices: `/dev/video*` nodes that say they capture (a webcam also has
    /// metadata nodes, which do not). None when zbar is missing, since nothing could read them.
    static func devices() -> [CameraDevice] {
        guard ZBar.shared != nil, let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        return names
            .filter { $0.hasPrefix("video") && Int($0.dropFirst(5)) != nil }
            .sorted { Int($0.dropFirst(5))! < Int($1.dropFirst(5))! }
            .compactMap { node in
                let path = "/dev/\(node)"
                guard let name = captureName(path) else { return nil }
                return CameraDevice(id: path, name: name)
            }
    }

    /// The first; Linux has no system-wide choice of camera.
    static func preferred(among devices: [CameraDevice]) -> CameraDevice? { devices.first }

    /// The device's name when it is a video capture device, else `nil`. VIDIOC_QUERYCAP opens
    /// nothing on the device and does not light it.
    private static func captureName(_ path: String) -> String? {
        #if os(Linux)
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        // A node the user may not open is still a camera; the sheet says why it cannot be used.
        guard fd >= 0 else { return errno == EACCES ? "Camera (\(path))" : nil }
        defer { close(fd) }
        // struct v4l2_capability: driver[16], card[32], bus_info[32], version, capabilities,
        // device_caps, reserved[3]; VIDIOC_QUERYCAP is _IOR('V', 0, it).
        var caps = [UInt8](repeating: 0, count: 104)
        guard caps.withUnsafeMutableBytes({ ioctl(fd, UInt(0x8068_5600), $0.baseAddress!) }) == 0 else { return nil }
        func word(_ offset: Int) -> UInt32 { caps[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let capabilities = word(84)
        let deviceCaps = capabilities & 0x8000_0000 != 0 ? word(88) : capabilities   // V4L2_CAP_DEVICE_CAPS
        guard deviceCaps & 0x1 != 0 else { return nil }                                // V4L2_CAP_VIDEO_CAPTURE
        let card = String(decoding: caps[16..<48].prefix { $0 != 0 }, as: UTF8.self)
        return card.isEmpty ? path : card
        #else
        return FileManager.default.isReadableFile(atPath: path) ? "Camera (\(path))" : nil
        #endif
    }

    /// Every QR code in an image on the clipboard, or the clipboard's text when it holds no
    /// image with a code: a screenshot of a code and a copied code are both worth reading.
    /// (`textsFromPasteboard` upstream; GTK's clipboard is read asynchronously.)
    @MainActor static func textsFromClipboard(_ clipboard: OpaquePointer) async -> [String] {
        // Another program offers an image by MIME type, which GTK turns into a texture; reading
        // one from a clipboard that holds only text fails at once.
        if let texture = await readTexture(clipboard) {
            let codes = QRCode.decodeAll(texture)
            if !codes.isEmpty { return codes }
        }
        return await readText(clipboard).map { [$0] } ?? []
    }

    /// The first of them.
    @MainActor static func textFromClipboard(_ clipboard: OpaquePointer) async -> String? {
        await textsFromClipboard(clipboard).first
    }

    private final class Reply<T>: @unchecked Sendable {
        let continuation: CheckedContinuation<T?, Never>
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    }

    @MainActor private static func readTexture(_ clipboard: OpaquePointer) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Reply<PlatformImage>(continuation)).toOpaque()
            gdk_clipboard_read_texture_async(clipboard, nil, { source, result, data in
                let reply = Unmanaged<Reply<PlatformImage>>.fromOpaque(data!).takeRetainedValue()
                let texture = gdk_clipboard_read_texture_finish(OpaquePointer(source), result, nil)
                reply.continuation.resume(returning: texture.map { PlatformImage(texture: $0) })
            }, box)
        }
    }

    @MainActor private static func readText(_ clipboard: OpaquePointer) async -> String? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Reply<String>(continuation)).toOpaque()
            gdk_clipboard_read_text_async(clipboard, nil, { source, result, data in
                let reply = Unmanaged<Reply<String>>.fromOpaque(data!).takeRetainedValue()
                guard let text = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil) else {
                    reply.continuation.resume(returning: nil)
                    return
                }
                defer { g_free(text) }
                reply.continuation.resume(returning: String(cString: text))
            }, box)
        }
    }
}

/// Tells the model whether a camera is attached, now and as cameras come and go (a webcam
/// plugged in or out). Watches `/dev`, and looks again a moment after a change, since udev
/// gives a new node its permissions after making it. The app makes one and keeps it.
@MainActor
final class CameraWatcher {
    private var monitor: UnsafeMutablePointer<GFileMonitor>?
    private var pending: Task<Void, Never>?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        let report = { onChange(!QRCamera.devices().isEmpty) }
        report()
        guard ZBar.shared != nil else { return }
        let dev = g_file_new_for_path("/dev")
        defer { g_object_unref(UnsafeMutableRawPointer(dev)) }
        guard let monitor = g_file_monitor_directory(dev, G_FILE_MONITOR_NONE, nil, nil) else { return }
        self.monitor = monitor
        Signals.connect(Widget(monitor), "changed") { [weak self] in
            self?.pending?.cancel()
            self?.pending = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                report()
            }
        }
    }
}

/// Reads QR codes from a camera: zbar's video module captures on a thread of its own, each
/// frame is scanned there, and each distinct code is yielded on `codes`; the frames are offered
/// on `frames` for the preview. Nothing is recorded, kept or logged; a code may be a secret key.
@MainActor
final class QRCaptureSession {
    let codes: AsyncStream<String>
    /// The picture, at most a frame or two behind.
    let frames: AsyncStream<PlatformImage>
    /// Why the camera could not start or stopped, when it did.
    let failures: AsyncStream<String>

    private let codeSink: AsyncStream<String>.Continuation
    private let frameSink: AsyncStream<PlatformImage>.Continuation
    private let failureSink: AsyncStream<String>.Continuation
    private var run: Run?

    /// One capture: the thread stops at the next frame once `stopped` is set, and signals
    /// `done` when it has let go of the device.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped = false
        let done = DispatchSemaphore(value: 0)
        var stopped: Bool { lock.withLock { _stopped } }
        func stop() { lock.withLock { _stopped = true } }
    }

    init() {
        (codes, codeSink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(32))
        (frames, frameSink) = AsyncStream.makeStream(of: PlatformImage.self, bufferingPolicy: .bufferingNewest(1))
        (failures, failureSink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(4))
    }

    /// Starts (or switches to) the camera with this id.
    func start(deviceID: String) {
        let previous = run
        stop()
        let run = Run()
        self.run = run
        let (codes, frames, failures) = (codeSink, frameSink, failureSink)
        let thread = Thread {
            // The same camera opens only once the last capture has closed it (a frame at most,
            // unless that camera stopped giving any).
            _ = previous?.done.wait(timeout: .now() + 2)
            Self.capture(device: deviceID, run: run, codes: codes, frames: frames, failures: failures)
        }
        thread.name = "org.tezos.signet.qr-capture"
        thread.start()
    }

    /// Stops the camera; its light goes out once the thread has taken its last frame.
    func stop() {
        run?.stop()
        run = nil
    }

    private nonisolated static func capture(device: String, run: Run, codes: AsyncStream<String>.Continuation,
                                            frames: AsyncStream<PlatformImage>.Continuation, failures: AsyncStream<String>.Continuation) {
        defer { run.done.signal() }
        guard !run.stopped, let zbar = ZBar.shared, let video = zbar.videoCreate() else { return }
        defer { zbar.videoDestroy(video) }
        // Small frames are plenty for a code held up to a webcam, and quick to scan.
        _ = zbar.videoRequestSize(video, 640, 480)
        guard zbar.videoOpen(video, device) == 0 else {
            if !run.stopped {
                failures.yield(access(device, R_OK | W_OK) == 0
                               ? "The camera could not be opened; another program may be using it."
                               : "Signet may not use the camera. Your user needs access to \(device), usually by being in the video group.")
            }
            return
        }
        guard zbar.negotiateFormat(video, nil) == 0, zbar.videoEnable(video, 1) == 0 else {
            if !run.stopped { failures.yield("The camera gives no picture Signet can read.") }
            return
        }
        defer { _ = zbar.videoEnable(video, 0) }
        let scanner = ZBar.Scanner(zbar)
        var seen: [String: Date] = [:]
        var lastFrame = Date.distantPast
        while !run.stopped {
            guard let image = zbar.videoNextImage(video) else {
                if !run.stopped { failures.yield("The camera stopped.") }
                return
            }
            defer { zbar.imageDestroy(image) }
            guard !run.stopped else { return }
            // Every code in view is reported (a recovery sheet can show several parts of one key
            // at once). A code stays in view for many frames; say it once, and again after a
            // pause so a code the sheet could not use can be tried again.
            if let gray = zbar.imageConvert(image, ZBar.y800) {
                let now = Date()
                seen = seen.filter { now.timeIntervalSince($0.value) <= 3 }
                for code in scanner.scan(gray) where seen[code] == nil {
                    seen[code] = now
                    codes.yield(code)
                }
                zbar.imageDestroy(gray)
            }
            // The preview at about fifteen frames a second.
            let now = Date()
            if now.timeIntervalSince(lastFrame) >= 1.0 / 15, let picture = zbar.texture(of: image) {
                lastFrame = now
                frames.yield(picture)
            }
        }
    }
}

extension QRCode {
    /// Decodes the first QR code found in `image`.
    static func decode(_ image: PlatformImage) -> String? { decodeAll(image).first }

    /// Every QR code found in `image`: a page of a recovery sheet can carry several. Empty when
    /// libzbar is missing.
    static func decodeAll(_ image: PlatformImage) -> [String] {
        guard let zbar = ZBar.shared, image.width > 0, image.height > 0 else { return [] }
        // GDK gives premultiplied ARGB in native order; zbar wants grey. Transparent pixels are
        // white, as the page a screenshot was taken of, and a white border stands in for the
        // quiet zone a cropped code (or `QRCode.image`, which has none) lacks.
        let (width, height) = (image.width, image.height)
        let stride = width * 4
        var argb = [UInt8](repeating: 0, count: stride * height)
        argb.withUnsafeMutableBufferPointer { gdk_texture_download(image.texture, $0.baseAddress, gsize(stride)) }
        let border = max(16, max(width, height) / 8)
        let (paddedWidth, paddedHeight) = (width + 2 * border, height + 2 * border)
        var gray = [UInt8](repeating: 0xFF, count: paddedWidth * paddedHeight)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                // Little-endian ARGB32: blue, green, red, alpha.
                let (b, g, r, a) = (Int(argb[i]), Int(argb[i + 1]), Int(argb[i + 2]), Int(argb[i + 3]))
                gray[(y + border) * paddedWidth + x + border] = UInt8(min(255, (r * 77 + g * 150 + b * 29) / 256 + 255 - a))
            }
        }
        guard let frame = zbar.imageCreate() else { return [] }
        defer { zbar.imageDestroy(frame) }
        return gray.withUnsafeBytes { bytes in
            zbar.imageSetFormat(frame, ZBar.y800)
            zbar.imageSetSize(frame, UInt32(paddedWidth), UInt32(paddedHeight))
            zbar.imageSetData(frame, bytes.baseAddress, UInt(bytes.count), nil)
            return ZBar.Scanner(zbar).scan(frame)
        }
    }
}

/// libzbar, opened with `dlopen` so it is wanted only by Scan QR code: the functions Signet
/// uses, from `zbar.h`.
final class ZBar: @unchecked Sendable {
    static let shared = ZBar()

    /// zbar's fourcc for 8-bit grey, the only format its scanner takes, and for packed RGB.
    static let y800 = fourcc("Y800")
    static let rgb3 = fourcc("RGB3")
    private static func fourcc(_ code: String) -> UInt {
        code.utf8.reversed().reduce(0) { $0 << 8 | UInt($1) }
    }

    typealias Object = OpaquePointer
    let scannerCreate: @convention(c) () -> Object?
    let scannerDestroy: @convention(c) (Object?) -> Void
    let scannerSetConfig: @convention(c) (Object?, Int32, Int32, Int32) -> Int32
    let scanImage: @convention(c) (Object?, Object?) -> Int32
    let imageCreate: @convention(c) () -> Object?
    let imageDestroy: @convention(c) (Object?) -> Void
    let imageSetFormat: @convention(c) (Object?, UInt) -> Void
    let imageSetSize: @convention(c) (Object?, UInt32, UInt32) -> Void
    let imageSetData: @convention(c) (Object?, UnsafeRawPointer?, UInt, UnsafeRawPointer?) -> Void
    let imageConvert: @convention(c) (Object?, UInt) -> Object?
    let imageGetData: @convention(c) (Object?) -> UnsafeRawPointer?
    let imageGetDataLength: @convention(c) (Object?) -> UInt
    let imageGetWidth: @convention(c) (Object?) -> UInt32
    let imageGetHeight: @convention(c) (Object?) -> UInt32
    let imageFirstSymbol: @convention(c) (Object?) -> Object?
    let symbolNext: @convention(c) (Object?) -> Object?
    let symbolGetType: @convention(c) (Object?) -> Int32
    let symbolGetData: @convention(c) (Object?) -> UnsafePointer<CChar>?
    let symbolGetDataLength: @convention(c) (Object?) -> UInt32
    let videoCreate: @convention(c) () -> Object?
    let videoDestroy: @convention(c) (Object?) -> Void
    let videoOpen: @convention(c) (Object?, UnsafePointer<CChar>?) -> Int32
    let videoRequestSize: @convention(c) (Object?, UInt32, UInt32) -> Int32
    let negotiateFormat: @convention(c) (Object?, Object?) -> Int32
    let videoEnable: @convention(c) (Object?, Int32) -> Int32
    let videoNextImage: @convention(c) (Object?) -> Object?

    private init?() {
        guard let handle = dlopen("libzbar.so.0", RTLD_NOW | RTLD_LOCAL) ?? dlopen("libzbar.so", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func load<T>(_ name: String) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw CocoaError(.featureUnsupported) }
            return unsafeBitCast(symbol, to: T.self)
        }
        do {
            scannerCreate = try load("zbar_image_scanner_create")
            scannerDestroy = try load("zbar_image_scanner_destroy")
            scannerSetConfig = try load("zbar_image_scanner_set_config")
            scanImage = try load("zbar_scan_image")
            imageCreate = try load("zbar_image_create")
            imageDestroy = try load("zbar_image_destroy")
            imageSetFormat = try load("zbar_image_set_format")
            imageSetSize = try load("zbar_image_set_size")
            imageSetData = try load("zbar_image_set_data")
            imageConvert = try load("zbar_image_convert")
            imageGetData = try load("zbar_image_get_data")
            imageGetDataLength = try load("zbar_image_get_data_length")
            imageGetWidth = try load("zbar_image_get_width")
            imageGetHeight = try load("zbar_image_get_height")
            imageFirstSymbol = try load("zbar_image_first_symbol")
            symbolNext = try load("zbar_symbol_next")
            symbolGetType = try load("zbar_symbol_get_type")
            symbolGetData = try load("zbar_symbol_get_data")
            symbolGetDataLength = try load("zbar_symbol_get_data_length")
            videoCreate = try load("zbar_video_create")
            videoDestroy = try load("zbar_video_destroy")
            videoOpen = try load("zbar_video_open")
            videoRequestSize = try load("zbar_video_request_size")
            negotiateFormat = try load("zbar_negotiate_format")
            videoEnable = try load("zbar_video_enable")
            videoNextImage = try load("zbar_video_next_image")
        } catch {
            dlclose(handle)
            return nil
        }
    }

    /// A scanner for QR codes only, for one use on one thread.
    final class Scanner {
        private let zbar: ZBar
        private let scanner: Object?

        init(_ zbar: ZBar) {
            self.zbar = zbar
            scanner = zbar.scannerCreate()
            // Off for every symbology (ZBAR_NONE, ZBAR_CFG_ENABLE), then on for QR (ZBAR_QRCODE).
            _ = zbar.scannerSetConfig(scanner, 0, 0, 0)
            _ = zbar.scannerSetConfig(scanner, 64, 0, 1)
        }

        deinit { zbar.scannerDestroy(scanner) }

        /// The text of every QR code in a grey (Y800) image.
        func scan(_ image: Object) -> [String] {
            guard scanner != nil, zbar.scanImage(scanner, image) > 0 else { return [] }
            var texts: [String] = []
            var symbol = zbar.imageFirstSymbol(image)
            while let current = symbol {
                if zbar.symbolGetType(current) == 64, let data = zbar.symbolGetData(current) {
                    let bytes = UnsafeRawBufferPointer(start: data, count: Int(zbar.symbolGetDataLength(current)))
                    texts.append(String(decoding: bytes, as: UTF8.self))
                }
                symbol = zbar.symbolNext(current)
            }
            return texts
        }
    }

    /// A frame as a texture for the preview.
    func texture(of image: Object) -> PlatformImage? {
        guard let rgb = imageConvert(image, Self.rgb3) else { return nil }
        defer { imageDestroy(rgb) }
        let (width, height) = (Int(imageGetWidth(rgb)), Int(imageGetHeight(rgb)))
        guard width > 0, height > 0, let data = imageGetData(rgb), Int(imageGetDataLength(rgb)) >= width * height * 3,
              let bytes = g_bytes_new(data, gsize(width * height * 3)) else { return nil }
        defer { g_bytes_unref(bytes) }
        return gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_R8G8B8, bytes, gsize(width * 3)).map(PlatformImage.init)
    }
}
