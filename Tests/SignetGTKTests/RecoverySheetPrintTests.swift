import CAdwaita
import Foundation
import Testing
@testable import Signet

/// The recovery sheet as the port draws it (cairo and Pango, where upstream renders SwiftUI into
/// a PDF): its pages, and that the codes printed on them read back with Scan QR code's decoder.
/// Upstream's own `RecoverySheetTests` count PDF pages with PDFKit, which Linux lacks.
@MainActor
struct RecoverySheetPrintTests {
    private static let clear = Base58.checkEncode(prefix: TezosPrefix.edsk, payload: [UInt8](repeating: 7, count: 32))
    private static let encrypted = Base58.checkEncode(prefix: [7, 90, 60, 179, 41], payload: [UInt8](repeating: 3, count: 56))
    private static let longSecret = Base58.checkEncode(prefix: [9, 57, 116, 57], payload: (0..<3872).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private static let longPublic = Base58.checkEncode(prefix: TezosPrefix.edpk, payload: (0..<1312).map { UInt8(truncatingIfNeeded: $0 &* 17) })
    private static let wallet = Wallet(alias: "Savings", address: Address("tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb"), keyKind: .encrypted)
    private static let paper = CGSize(width: 595, height: 842)

    /// The page objects in a PDF cairo wrote (`/Type /Page`, not the `/Type /Pages` tree).
    private static func pageCount(_ pdf: Data) -> Int {
        String(decoding: pdf, as: UTF8.self).matches(of: /\/Type \/Page\b(?!s)/).count
    }

    /// One page drawn at twice its size, as a camera or a screenshot would see it.
    private static func picture(of sheet: RecoverySheet, page: Int) throws -> PlatformImage {
        let (width, height) = (Int32(paper.width * 2), Int32(paper.height * 2))
        let surface = try #require(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height))
        defer { cairo_surface_destroy(surface) }
        let cr = try #require(cairo_create(surface))
        cairo_scale(cr, 2, 2)
        RecoverySheetPainter(sheet: sheet).draw(page: page, on: cr, size: paper)
        cairo_destroy(cr)
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        let bytes = try #require(g_bytes_new(cairo_image_surface_get_data(surface), gsize(stride * Int(height))))
        defer { g_bytes_unref(bytes) }
        return PlatformImage(texture: try #require(gdk_memory_texture_new(width, height, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride))))
    }

    @Test func rendersOnePageForAShortKey() {
        let sheet = RecoverySheet(wallet: Self.wallet, key: .init(clear: Self.clear, encrypted: Self.encrypted), version: "1.0")
        let pdf = RecoverySheetPrinter.pdfData(for: sheet)
        if let path = ProcessInfo.processInfo.environment["SIGNET_RECOVERY_SHEET_OUTPUT"] { try? pdf.write(to: URL(fileURLWithPath: path)) }
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        #expect(Self.pageCount(pdf) == 1)
    }

    @Test func rendersALongKeyOverSeveralPages() {
        let wallet = Wallet(alias: "Quantum", address: Self.wallet.address, publicKey: Self.longPublic, keyKind: .unencrypted)
        let sheet = RecoverySheet(wallet: wallet, key: .init(clear: Self.longSecret, encrypted: nil), version: "1.0")
        let pdf = RecoverySheetPrinter.pdfData(for: sheet)
        if let path = ProcessInfo.processInfo.environment["SIGNET_RECOVERY_SHEET_LONG_OUTPUT"] { try? pdf.write(to: URL(fileURLWithPath: path)) }
        #expect(sheet.pageCount > 2)
        #expect(Self.pageCount(pdf) == sheet.pageCount)
    }

    @Test(.enabled(if: ZBar.shared != nil, "needs libzbar"))
    func thePrintedCodeScansBack() throws {
        for key in [WalletViewModel.ExportedKey(clear: Self.clear, encrypted: Self.encrypted), .init(clear: Self.clear, encrypted: nil)] {
            let sheet = RecoverySheet(wallet: Self.wallet, key: key, version: "1.0")
            let codes = QRCode.decodeAll(try Self.picture(of: sheet, page: 0))
            #expect(codes.map(QRPayload.classify) == [.secretKey(sheet.secretKey)])
        }
    }

    @Test(.enabled(if: ZBar.shared != nil, "needs libzbar"))
    func everyCodeOnAPageOfPartsScansBackIntoTheKey() throws {
        let sheet = RecoverySheet(wallet: Self.wallet, key: .init(clear: Self.longSecret, encrypted: nil), version: "1.0")
        var collector = KeyPartCollector()
        var outcome: KeyPartCollector.Outcome = .needMore
        for page in 1...sheet.codePages.count {
            let codes = QRCode.decodeAll(try Self.picture(of: sheet, page: page))
            // One picture of a page gives all of its codes.
            #expect(codes.count == sheet.codePages[page - 1].count)
            for code in codes {
                guard case .keyPart(let part) = QRPayload.classify(code) else {
                    Issue.record("a code on page \(page + 1) is not a key part")
                    continue
                }
                outcome = collector.add(part)
            }
        }
        #expect(outcome == .complete(Self.longSecret))
    }

    @Test(.enabled(if: ZBar.shared != nil, "needs libzbar"))
    func anImageWithNoCodeGivesNothing() throws {
        let blank = try #require(QRCode.image(for: "x"))
        #expect(QRCode.decodeAll(blank) == ["x"])
        let bytes = try #require(g_bytes_new([UInt8](repeating: 0xFF, count: 64 * 64 * 4), gsize(64 * 64 * 4)))
        defer { g_bytes_unref(bytes) }
        let white = PlatformImage(texture: try #require(gdk_memory_texture_new(64, 64, GDK_MEMORY_R8G8B8A8, bytes, 256)))
        #expect(QRCode.decodeAll(white).isEmpty)
    }
}
