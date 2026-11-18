import Foundation

/// The port's `FramedConnection` for upstream's `RemoteSignerClient.swift`, whose own sits on
/// Network.framework: one TCP or Unix socket to a remote signer carrying octez-signer's
/// length-prefixed messages, with the same `open`/`send`/`receive`/`close` and the same
/// wording for a refused connection or an unknown host. Each step runs on a queue of its own
/// and waits in `poll` a quarter of a second at a time, so `close` (or cancelling the task)
/// stops it promptly.
final class FramedConnection: @unchecked Sendable {
    private enum Target {
        case host(String, Int)
        case unix(String)
    }

    private let target: Target
    private let queue = DispatchQueue(label: "org.tezos.signet.remote-signer")
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var closed = false

    init(signer: RemoteSignerLocator) throws {
        switch signer.transport {
        case .tcp:
            guard (1...65535).contains(signer.port) else { throw RemoteSignerError.unreachable("invalid port") }
            target = .host(signer.host, signer.port)
        case .unix:
            target = .unix(signer.path)
        default:
            throw RemoteSignerError.unreachable("not a socket signer")
        }
    }

    deinit {
        if socket >= 0 { Glibc.close(socket) }
    }

    func open() async throws { try await run { try self.connect() } }

    func send(_ bytes: [UInt8]) async throws { try await run { try self.write(bytes) } }

    func receive(exactly count: Int) async throws -> [UInt8] { try await run { try self.read(count) } }

    func close() {
        lock.withLock {
            closed = true
            if socket >= 0 { shutdown(socket, Int32(SHUT_RDWR)) }
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try work() }) }
            }
        } onCancel: { close() }
    }

    // MARK: Steps, on `queue`

    private func connect() throws {
        switch target {
        case .host(let host, let port):
            var hints = addrinfo()
            #if os(Linux)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)   // an enum in glibc's headers
            #else
            hints.ai_socktype = SOCK_STREAM
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
                throw RemoteSignerError.unreachable("the host name could not be found")
            }
            defer { freeaddrinfo(first) }
            var failure: Int32 = 0
            var pointer: UnsafeMutablePointer<addrinfo>? = first
            while let info = pointer {
                pointer = info.pointee.ai_next
                let error = attempt(family: info.pointee.ai_family, type: info.pointee.ai_socktype, protocol: info.pointee.ai_protocol,
                                    address: info.pointee.ai_addr, length: info.pointee.ai_addrlen)
                if error == 0 { return }
                failure = error
            }
            throw Self.unreachable(failure)
        case .unix(let path):
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else { throw RemoteSignerError.unreachable("the socket path is too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            #if os(Linux)
            let type = Int32(SOCK_STREAM.rawValue)
            #else
            let type = SOCK_STREAM
            #endif
            let error = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    attempt(family: AF_UNIX, type: type, protocol: 0, address: $0, length: socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if error != 0 { throw Self.unreachable(error) }
        }
    }

    /// Connects one socket without blocking; 0 once connected (the socket kept), else the errno.
    private func attempt(family: Int32, type: Int32, protocol: Int32, address: UnsafePointer<sockaddr>?, length: socklen_t) -> Int32 {
        let candidate = Glibc.socket(family, type, `protocol`)
        guard candidate >= 0 else { return errno }
        _ = fcntl(candidate, F_SETFL, fcntl(candidate, F_GETFL) | O_NONBLOCK)
        var error: Int32 = 0
        if Glibc.connect(candidate, address, length) != 0 {
            error = errno
            if error == EINPROGRESS {
                error = wait(candidate, for: Int16(POLLOUT)) ? 0 : ECANCELED
                if error == 0 {
                    var status: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(candidate, SOL_SOCKET, SO_ERROR, &status, &size)
                    error = status
                }
            }
        }
        guard error == 0 else {
            Glibc.close(candidate)
            return error
        }
        let kept = lock.withLock { () -> Bool in
            guard !closed else { return false }
            socket = candidate
            return true
        }
        if !kept {
            Glibc.close(candidate)
            return ECANCELED
        }
        return 0
    }

    private func write(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            guard wait(socket, for: Int16(POLLOUT)) else { throw CancellationError() }
            let count = bytes.withUnsafeBytes { Glibc.send(socket, $0.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL)) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw Self.unreachable(errno)
            }
            sent += count
        }
    }

    private func read(_ count: Int) throws -> [UInt8] {
        var collected = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            guard wait(socket, for: Int16(POLLIN)) else { throw CancellationError() }
            let got = collected.withUnsafeMutableBytes { recv(socket, $0.baseAddress! + received, count - received, 0) }
            if got < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw Self.unreachable(errno)
            }
            if got == 0 {
                if isClosed { throw CancellationError() }
                throw RemoteSignerError.closed
            }
            received += got
        }
        return collected
    }

    /// Waits until `descriptor` is ready for `events`; false once the connection is closed.
    private func wait(_ descriptor: Int32, for events: Int16) -> Bool {
        while !isClosed {
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&entry, 1, 250)
            if ready > 0 { return !isClosed }
            if ready < 0, errno != EINTR { return true }   // let the read or write report it
        }
        return false
    }

    private static func unreachable(_ error: Int32) -> RemoteSignerError {
        if error == ECONNREFUSED { return .unreachable("nothing is listening there (connection refused)") }
        if error == ECANCELED { return .unreachable("the connection was closed") }
        return .unreachable(String(cString: strerror(error)))
    }
}
