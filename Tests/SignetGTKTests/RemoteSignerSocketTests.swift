import Foundation
import Testing
@testable import Signet

/// The port's `FramedConnection` (POSIX sockets in place of Network.framework) and upstream's
/// HTTP path on swift-corelibs-foundation, against a pretend signer on this machine that answers
/// as octez-signer 21 did in upstream's captured exchanges (`RemoteSignerTests`).
struct RemoteSignerSocketTests {
    static let alice = Address("tz1MHEJyAu3Jw6uHKqdkvbkwLPEwxgfvgXcG")
    static let aliceKey = "edpkuStAKZyEk99wkft2maSTVqAmj9HoCwf63y2HyMvhPP7MMH5crT"
    static let alicePublicKeyReply = Hex.decode("0000" + "69f1f01c04a09e8dec3f53e95f2ec95d2d65202b7af989f63a1d29aa32aead85")!
    static let signature = [UInt8](repeating: 0x5a, count: 64)

    /// One listening socket on 127.0.0.1 serving each connection on a thread of its own.
    final class FakeSigner: @unchecked Sendable {
        let port: Int
        private let listener: Int32
        private let lock = NSLock()
        private var _requests: [[UInt8]] = []
        var requests: [[UInt8]] { lock.withLock { _requests } }

        /// `answer` gets each request payload (or, for HTTP, the request line) and returns the
        /// reply, or nil to hang up without one.
        init(http: Bool = false, answer: @escaping @Sendable ([UInt8]) -> [UInt8]?) throws {
            #if os(Linux)
            let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            #endif
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian   // 127.0.0.1
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
            }
            guard bound, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
            port = Int(UInt16(bigEndian: address.sin_port))
            self.listener = listener
            Thread.detachNewThread { [self] in
                while true {
                    let connection = accept(listener, nil, nil)
                    guard connection >= 0 else { return }
                    Thread.detachNewThread { [self] in
                        defer { close(connection) }
                        if http { serveHTTP(connection, answer) } else { serveFrames(connection, answer) }
                    }
                }
            }
        }

        deinit {
            #if os(FreeBSD)
            shutdown(listener, Int32(SHUT_RDWR.rawValue))   // an enum in FreeBSD 15's headers
            #else
            shutdown(listener, Int32(SHUT_RDWR))
            #endif
            close(listener)
        }

        private func read(_ connection: Int32, _ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = bytes.withUnsafeMutableBytes { recv(connection, $0.baseAddress! + got, count - got, 0) }
                guard n > 0 else { return nil }
                got += n
            }
            return bytes
        }

        private func serveFrames(_ connection: Int32, _ answer: ([UInt8]) -> [UInt8]?) {
            while let header = read(connection, 2), let payload = read(connection, Int(header[0]) << 8 | Int(header[1])) {
                lock.withLock { _requests.append(payload) }
                guard let reply = answer(payload) else { return }
                let framed = [UInt8(reply.count >> 8), UInt8(reply.count & 0xff)] + reply
                _ = framed.withUnsafeBytes { send(connection, $0.baseAddress!, framed.count, Int32(MSG_NOSIGNAL)) }
            }
        }

        private func serveHTTP(_ connection: Int32, _ answer: ([UInt8]) -> [UInt8]?) {
            var head: [UInt8] = []
            while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard let byte = read(connection, 1) else { return }
                head += byte
            }
            let line = Array(head.prefix { $0 != 13 })
            lock.withLock { _requests.append(line) }
            guard let body = answer(line) else { return }
            let reply = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            _ = reply.withUnsafeBytes { send(connection, $0.baseAddress!, reply.count, Int32(MSG_NOSIGNAL)) }
        }
    }

    /// A port nothing listens on: one the system hands out, released again.
    static func unusedPort() -> Int {
        #if os(Linux)
        let probe = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian   // 127.0.0.1
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) == 0 && getsockname(probe, $0, &length) == 0 }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func locator(_ port: Int, transport: RemoteSignerLocator.Transport = .tcp) -> RemoteSignerLocator {
        RemoteSignerLocator(transport: transport, host: "127.0.0.1", port: port, address: Self.alice)
    }

    @Test func asksForAKeyAndSignsOverTCP() async throws {
        let signer = try FakeSigner { request in
            switch request.first {
            case 1: Self.alicePublicKeyReply
            case 2: [0, 0]                       // no authentication
            case 0: [0] + Self.signature
            default: [1] + Array(#"[{"kind":"temporary","id":"signer.unknown_request","msg":"x"}]"#.utf8)
            }
        }
        let service = NetworkRemoteSignerService(timeout: .seconds(10))
        #expect(try await service.publicKey(at: locator(signer.port)) == Self.aliceKey)
        #expect(try await service.authorizedKeys(at: locator(signer.port)) == nil)
        let data: [UInt8] = [3] + [UInt8](repeating: 0xab, count: 40)
        #expect(try await service.sign(data, at: locator(signer.port)) == .raw(Self.signature))
        // Signing asks about authentication and signs on one connection, as octez-client does.
        #expect(signer.requests.suffix(2).map { $0.first } == [2, 0])
        #expect(signer.requests.last == SignerWire.signRequest(address: Self.alice, data: data))
    }

    @Test func reportsASignerThatHangsUp() async throws {
        let signer = try FakeSigner { _ in nil }
        await #expect(throws: RemoteSignerError.closed) {
            try await NetworkRemoteSignerService(timeout: .seconds(10)).publicKey(at: locator(signer.port))
        }
    }

    @Test func givesUpOnASilentSigner() async throws {
        let signer = try FakeSigner { _ in
            Thread.sleep(forTimeInterval: 5)
            return nil
        }
        let started = Date()
        await #expect(throws: RemoteSignerError.timedOut) {
            try await NetworkRemoteSignerService(timeout: .seconds(1)).publicKey(at: locator(signer.port))
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func saysNothingIsListening() async throws {
        let port = Self.unusedPort()
        await #expect(throws: RemoteSignerError.unreachable("nothing is listening there (connection refused)")) {
            try await NetworkRemoteSignerService(timeout: .seconds(10)).publicKey(at: locator(port))
        }
    }

    @Test func asksForAKeyOverHTTP() async throws {
        let signer = try FakeSigner(http: true) { line in
            String(decoding: line, as: UTF8.self).hasPrefix("GET /keys/\(Self.alice.value) ") ? Array(#"{"public_key":"\#(Self.aliceKey)"}"#.utf8) : nil
        }
        let service = NetworkRemoteSignerService(timeout: .seconds(10))
        #expect(try await service.publicKey(at: locator(signer.port, transport: .http)) == Self.aliceKey)
        // A second request reuses the one long-lived session.
        #expect(try await service.publicKey(at: locator(signer.port, transport: .http)) == Self.aliceKey)
    }
}
