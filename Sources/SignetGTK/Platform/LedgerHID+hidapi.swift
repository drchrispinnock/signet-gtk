import CHidapi
import Foundation

/// Talks to Ledger devices over USB HID with hidapi, the Linux and BSD counterpart of upstream's
/// IOKit `LedgerHID` (the framing, `LedgerFraming` and `LedgerDevice` are upstream's, shared).
/// One exchange at a time per device. All state lives on a private thread; each open device
/// also has a reader thread that blocks in `hid_read_timeout` and hands reports to it. Callers
/// get their answer on `completionQueue`.
///
/// A device's id is its hidapi path (`/dev/hidrawN` on Linux), stable while it stays plugged in.
/// Linux only lets root open hidraw nodes unless a udev rule grants access; Ledger publishes one
/// (`20-hw1.rules`).
final class LedgerHID: @unchecked Sendable {
    enum HIDError: LocalizedError {
        case noSuchDevice
        case openFailed(String)
        case writeFailed(String)
        case timeout
        case busy
        case unplugged

        var errorDescription: String? {
            switch self {
            case .noSuchDevice: "No Ledger is connected. Plug it in, unlock it and open the Tezos app."
            case .openFailed(let reason): "Could not open the Ledger (\(reason))."
            case .writeFailed(let reason): "Could not write to the Ledger (\(reason))."
            case .timeout: "The Ledger did not answer in time."
            case .busy: "The Ledger is busy with another request."
            case .unplugged: "The Ledger was unplugged."
            }
        }
    }

    static let shared = LedgerHID()
    static let vendorID = 0x2c97
    /// Ledger's vendor-specific HID interface; the same devices also show keyboard/U2F interfaces.
    static let usagePage = 0xffa0

    private let queue = ThreadQueue(label: "org.tezos.signet.ledger-hid")
    private var open: [String: OpenDevice] = [:]

    private final class OpenDevice: @unchecked Sendable {
        let handle: OpaquePointer
        var tracker = LedgerFraming.ExchangeTracker()
        var pending: (id: Int, completion: (Result<[UInt8], Error>) -> Void, timer: DispatchWorkItem)?
        /// Cleared when the device is closed; the reader thread stops at its next wake-up.
        private let lock = NSLock()
        private var _reading = true
        var reading: Bool {
            get { lock.withLock { _reading } }
            set { lock.withLock { _reading = newValue } }
        }
        init(handle: OpaquePointer) { self.handle = handle }
    }

    private init() {
        hid_init()
    }

    /// Runs `body` on the HID thread and waits for it.
    private func onThread<T>(_ body: @escaping () -> T) -> T {
        if queue.isCurrent { return body() }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        nonisolated(unsafe) let body = body
        queue.async {
            result = body()
            done.signal()
        }
        done.wait()
        return result!
    }

    /// Ledgers currently plugged in (vendor-specific HID interface only).
    func devices() -> [LedgerDevice] {
        onThread { Self.enumerate().map(\.device).sorted { $0.id < $1.id } }
    }

    private static func enumerate() -> [(device: LedgerDevice, path: String)] {
        guard let list = hid_enumerate(UInt16(vendorID), 0) else { return [] }
        defer { hid_free_enumeration(list) }
        var found: [(LedgerDevice, String)] = []
        var cursor: UnsafeMutablePointer<hid_device_info>? = list
        while let info = cursor?.pointee {
            cursor = info.next
            // hidraw reports the usage page; the libusb backend does not, and there the
            // vendor interface is interface 0.
            let vendorInterface = info.usage_page == usagePage || (info.usage_page == 0 && info.interface_number == 0)
            guard vendorInterface, let path = info.path.map({ String(cString: $0) }) else { continue }
            let name = info.product_string.map(Self.string(fromWide:)) ?? ""
            found.append((LedgerDevice(id: path, name: name, productID: Int(info.product_id)), path))
        }
        return found
    }

    private static func string(fromWide pointer: UnsafeMutablePointer<wchar_t>) -> String {
        var scalars = String.UnicodeScalarView()
        var p = pointer
        while p.pointee != 0 {
            if let scalar = Unicode.Scalar(UInt32(bitPattern: p.pointee)) { scalars.append(scalar) }
            p += 1
        }
        return String(scalars)
    }

    private static func lastError(_ handle: OpaquePointer?) -> String {
        guard let message = hid_error(handle) else { return "unknown error" }
        return string(fromWide: UnsafeMutablePointer(mutating: message))
    }

    /// Sends one APDU and delivers the response (data ‖ status word) or an error.
    func exchange(deviceID: String, apdu: [UInt8], timeout: TimeInterval, completionQueue: ThreadQueue, completion: @escaping @Sendable (Result<[UInt8], Error>) -> Void) {
        queue.async { [self] in
            let finish: (Result<[UInt8], Error>) -> Void = { result in
                nonisolated(unsafe) let result = result
                completionQueue.async { completion(result) }
            }
            do {
                let open = try openDevice(id: deviceID)
                guard open.pending == nil else { throw HIDError.busy }
                let exchangeID = try open.tracker.start()
                let timer = DispatchWorkItem { [weak self] in
                    self?.timedOut(deviceID: deviceID, exchangeID: exchangeID)
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                open.pending = (exchangeID, finish, timer)
                for packet in LedgerFraming.packets(for: apdu) {
                    // hidapi wants the report id first; Ledger's reports have none (0).
                    let report = [0] + packet
                    let written = report.withUnsafeBufferPointer { hid_write(open.handle, $0.baseAddress, $0.count) }
                    guard written == report.count else {
                        // A half-written APDU leaves the device in an unknown state: drop the channel.
                        let reason = Self.lastError(open.handle)
                        open.pending = nil
                        timer.cancel()
                        open.tracker.abandon(exchangeID)
                        desynchronise(open)
                        throw HIDError.writeFailed(reason)
                    }
                }
            } catch LedgerFraming.ExchangeTracker.TrackerError.busy {
                finish(.failure(HIDError.busy))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func openDevice(id: String) throws -> OpenDevice {
        if let existing = open[id] { return existing }
        guard Self.enumerate().contains(where: { $0.path == id }) else { throw HIDError.noSuchDevice }
        guard let handle = hid_open_path(id) else { throw HIDError.openFailed(Self.lastError(nil)) }
        let entry = OpenDevice(handle: handle)
        open[id] = entry
        let reader = Thread { [weak self] in self?.read(from: entry, id: id) }
        reader.name = "org.tezos.signet.ledger-hid.reader"
        reader.start()
        return entry
    }

    /// The reader thread: blocks for reports and passes each to the HID thread. A read error
    /// means the device went away. The handle is closed here, once reading has stopped.
    private func read(from entry: OpenDevice, id: String) {
        var buffer = [UInt8](repeating: 0, count: LedgerFraming.packetSize)
        while entry.reading {
            let count = buffer.withUnsafeMutableBufferPointer { hid_read_timeout(entry.handle, $0.baseAddress, $0.count, 100) }
            if count < 0 {
                queue.async { [weak self] in self?.removed(entry, id: id) }
                break
            }
            guard count > 0 else { continue }
            let packet = Array(buffer[0..<Int(count)])
            queue.async { [weak self] in self?.received(packet, on: entry) }
        }
        entry.reading = false
        hid_close(entry.handle)
    }

    /// A timed-out exchange may still be answered later; that answer must not reach the next
    /// exchange, so the channel is closed and the device reopened fresh next time (S22).
    private func timedOut(deviceID: String, exchangeID: Int) {
        guard let entry = open[deviceID], let pending = entry.pending, pending.id == exchangeID else { return }
        entry.pending = nil
        entry.tracker.abandon(exchangeID)
        desynchronise(entry)
        pending.completion(.failure(HIDError.timeout))
    }

    private func received(_ packet: [UInt8], on entry: OpenDevice) {
        guard entry.reading, let pending = entry.pending else { return }   // nothing in flight: a stale report, dropped
        do {
            guard let done = try entry.tracker.receive(packet), done.id == pending.id else { return }
            entry.pending = nil
            pending.timer.cancel()
            pending.completion(.success(done.response))
        } catch {
            entry.pending = nil
            pending.timer.cancel()
            desynchronise(entry)
            pending.completion(.failure(error))
        }
    }

    /// Stops listening to the device; its reader closes it. Late reports from it are never
    /// delivered; the next exchange opens it again with a fresh tracker.
    private func desynchronise(_ entry: OpenDevice) {
        for (id, candidate) in open where candidate === entry { open[id] = nil }
        entry.reading = false
    }

    private func removed(_ entry: OpenDevice, id: String) {
        guard open[id] === entry else { return }
        open[id] = nil
        if let pending = entry.pending {
            entry.pending = nil
            pending.timer.cancel()
            pending.completion(.failure(HIDError.unplugged))
        }
    }
}
