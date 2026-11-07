import Foundation
import Testing
@testable import Signet

/// The GTK port's own copies of upstream policy, checked against the pinned upstream so they
/// cannot drift apart unnoticed (audit 2026-11-05, G06/T03).
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
