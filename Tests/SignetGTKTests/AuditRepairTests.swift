import Foundation
import Testing
@testable import Signet

/// The GTK port's own copies of upstream policy, checked against the pinned upstream so they
/// cannot drift apart unnoticed (audit 2026-11-05, G06/T03), and the GTK console's handling of
/// key material (K01).
struct PortPolicyTests {
    /// The names in a `static let signingCalls: Set<String> = [ … ]` declaration.
    static func declaredSigningCalls(in source: String) -> Set<String>? {
        guard let body = source.firstMatch(of: /static let signingCalls: Set<String> = \[([^\]]+)\]/)?.output.1 else { return nil }
        return Set(body.matches(of: /"([^"]+)"/).map { String($0.output.1) })
    }

    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func signingCallsMatchThePinnedUpstream() throws {
        let file = Self.packageRoot.appendingPathComponent("upstream/Signet/Services/TaquitoBridge.swift")
        let upstream = try #require(Self.declaredSigningCalls(in: String(contentsOf: file, encoding: .utf8)))
        #expect(upstream.contains("sendTokenTransfer") && upstream.contains("ledgerAppVersion"))
        #expect(TaquitoBridge.signingCalls == upstream)
        // The comparison notices a missing entry.
        #expect(TaquitoBridge.signingCalls.subtracting(["sendTokenTransfer"]) != upstream)
    }

    @Test func tokenTransfersAreSigningCalls() {
        #expect(TaquitoBridge.kind(of: "sendTokenTransfer") == .signing)
    }
}

struct ConsoleKeyMaterialTests {
    @Test func uuidSeedsAreRedacted() {
        let seed = "3f2c9a4e-1b7d-4c8e-9a0f-5d6e7f8a9b0c"
        let line = TaquitoBridge.redactedLine("[warn] Generating new key pair with seed \(seed)")
        #expect(!line.contains(seed) && !line.contains("3f2c9a4e"))
        #expect(line == "[warn] Generating new key pair with seed <uuid>")
    }

    /// Runs `script` with the bridge's console installed and returns what it logged.
    private func logged(_ script: String) throws -> [String] {
        let context = try #require(JSContext())
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        context.setObject(JSValue(function: "__signet_log", in: context) { args in
            lines.all.append(args.count > 1 ? args[1].toString() : "")
            return nil
        }, forKeyedSubscript: "__signet_log")
        context.evaluateScript(TaquitoBridge.consoleScript)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        return lines.all
    }

    @Test func transportObjectsAreLoggedWithoutTheirKeyPair() throws {
        let lines = try logged("""
        var secretKey = new Uint8Array(64); for (var i = 0; i < 64; i++) secretKey[i] = 200 + (i % 50);
        var transport = { type: "p2p", client: { keyPair: { secretKey: secretKey, publicKey: new Uint8Array(32) } } };
        console.log("[TRANSPORT] notifying listeners", transport);
        var plain = {}; for (var j = 0; j < 64; j++) plain[j] = 200 + (j % 50);
        console.debug({ client: { box: plain, list: Array.from(secretKey) } });
        console.log({ privateKey: "edskSecret", seed: "abc", publicKey: "edpkPublic", count: 3, hasSecret: true });
        """)
        #expect(lines.count == 3)
        for line in lines { #expect(!line.contains("200,") && !line.contains(":200") && !line.contains("edskSecret")) }
        #expect(lines[0].contains("\"keyPair\":\"<redacted>\"") && lines[0].contains("\"type\":\"p2p\""))
        #expect(lines[1] == #"{"client":{"box":"<64 bytes>","list":"<64 bytes>"}}"#)
        #expect(lines[2] == #"{"privateKey":"<redacted>","seed":"<redacted>","publicKey":"edpkPublic","count":3,"hasSecret":true}"#)
    }

    @Test func ordinaryObjectsAreUnchanged() throws {
        let lines = try logged(#"console.log("fetch", { status: 200, ids: [1, 2, 3], nested: { a: "b" } }, null, 7);"#)
        #expect(lines == [#"fetch {"status":200,"ids":[1,2,3],"nested":{"a":"b"}} null 7"#])
    }
}
