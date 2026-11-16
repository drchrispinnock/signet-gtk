import CAdwaita
import Foundation

/// What goes on a printed recovery sheet for one account: enough to bring the account back
/// with Scan QR code or Import account, and nothing that is not already in the Export sheet.
/// The secret is printed as it is stored, so a password-protected key stays protected on
/// paper and the sheet leaves a box for the password to be written in by hand. Upstream's
/// `RecoverySheet` (`Views/RecoverySheet.swift`), with a `PlatformImage` for its code.
struct RecoverySheet: Equatable, Sendable {
    let alias: String
    let address: Address
    let publicKey: String?
    /// The key the QR code carries: the octez-encrypted form when there is one, else the clear key.
    let secretKey: String
    let isEncrypted: Bool
    let date: Date
    let version: String

    init(wallet: Wallet, key: WalletViewModel.ExportedKey, date: Date = Date(), version: String = RecoverySheet.appVersion) {
        alias = wallet.alias
        address = wallet.address
        publicKey = wallet.publicKey
        secretKey = key.encrypted ?? key.clear
        isEncrypted = key.encrypted != nil
        self.date = date
        self.version = version
    }

    /// Empty in a SwiftPM build, which has no Info.plist; the sheet then leaves the version out.
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// The QR code of the secret key, or `nil` when the key is too long for one (a tz5 key is).
    func qrImage(size: CGFloat = 1000) -> PlatformImage? { QRCode.image(for: secretKey, size: size) }

    /// False when the key is too long for one QR code (a tz5 key). The sheet then carries the
    /// key as several codes on following pages (`keyParts`), which Scan QR code puts back
    /// together, and after them as numbered lines of text for when a code cannot be read.
    var hasQRCode: Bool { QRCode.modules(for: secretKey) != nil }

    /// The codes of a key too long for one; empty when one code carries it.
    var keyParts: [KeyPart] { hasQRCode ? [] : KeyPart.split(secretKey) }

    static let codesPerPage = 4

    /// The pages of codes, four to a page so each prints large enough for a webcam.
    var codePages: [[KeyPart]] {
        let parts = keyParts
        return stride(from: 0, to: parts.count, by: Self.codesPerPage).map { Array(parts[$0..<min($0 + Self.codesPerPage, parts.count)]) }
    }

    static let lineLength = 90
    static let linesPerPage = 60

    /// A long key cut into lines short enough to keep one's place in.
    static func lines(of key: String) -> [String] {
        var lines: [String] = []
        var rest = Substring(key)
        while !rest.isEmpty {
            lines.append(String(rest.prefix(lineLength)))
            rest = rest.dropFirst(lineLength)
        }
        return lines
    }

    /// One page of the secret key's text.
    struct KeyPage: Equatable, Sendable {
        let lines: [String]
        /// The number of the first line, counting from 1 across all pages.
        let firstLine: Int
        let part: Int
        let parts: Int
    }

    /// The pages of key text at the end: none when one QR code carries the key.
    var secretKeyPages: [KeyPage] {
        guard !hasQRCode else { return [] }
        let lines = Self.lines(of: secretKey)
        let starts = Array(stride(from: 0, to: lines.count, by: Self.linesPerPage))
        return starts.enumerated().map { index, start in
            KeyPage(lines: Array(lines[start..<min(start + Self.linesPerPage, lines.count)]), firstLine: start + 1, part: index + 1, parts: starts.count)
        }
    }

    var pageCount: Int { 1 + codePages.count + secretKeyPages.count }
}

/// Draws the pages of a recovery sheet with cairo and Pango, in black on white whatever the
/// app's appearance, at the paper's size in points: upstream's `RecoverySheetPage`,
/// `RecoverySheetCodesPage` and `RecoverySheetKeyPage`, laid out top to bottom by hand.
@MainActor
struct RecoverySheetPainter {
    let sheet: RecoverySheet

    nonisolated static let margin = 54.0

    /// Page `index` (from 0) of `sheet.pageCount`.
    func draw(page index: Int, on cr: OpaquePointer, size: CGSize) {
        cairo_save(cr)
        defer { cairo_restore(cr) }
        cairo_set_source_rgb(cr, 1, 1, 1)
        cairo_rectangle(cr, 0, 0, size.width, size.height)
        cairo_fill(cr)
        cairo_set_source_rgb(cr, 0, 0, 0)
        var page = Page(cr: cr, size: size)
        let codePages = sheet.codePages
        if index == 0 {
            drawFirst(&page)
        } else if index <= codePages.count {
            drawCodes(&page, parts: codePages[index - 1], number: index)
        } else if let keyPage = sheet.secretKeyPages[safe: index - 1 - codePages.count] {
            drawKey(&page, keyPage)
        }
    }

    private func drawFirst(_ page: inout Page) {
        let hasQRCode = sheet.hasQRCode
        let partCount = sheet.keyParts.count
        let left = Self.margin
        let width = page.contentWidth

        // The icon, and the title over a rule.
        page.icon(x: left, y: page.y, side: 64)
        let titleX = left + 64 + 18
        // On one line as upstream's, smaller where the font is wider than the Mac's.
        let title = page.layout("Signet Tezos Wallet Recovery Sheet", size: 22, weight: .semibold, width: nil)
        let titleSize = 22 * min(1, (width - 82) / page.size(of: title).width)
        g_object_unref(UnsafeMutableRawPointer(title))
        let titleHeight = page.measure("Signet Tezos Wallet Recovery Sheet", size: titleSize, weight: .semibold, width: width - 82)
        let titleTop = page.y + (64 - (titleHeight + 4 + 1.5)) / 2
        page.text("Signet Tezos Wallet Recovery Sheet", x: titleX, y: titleTop, width: width - 82, size: titleSize, weight: .semibold)
        page.rule(x: titleX, y: titleTop + titleHeight + 4, width: width - 82, thickness: 1.5)
        page.y += 64 + 22

        page.y += page.text(sheet.alias, size: 17, weight: .semibold) + 3
        let printed = "Printed \(sheet.date.formatted(date: .long, time: .omitted))\(sheet.version.isEmpty ? "" : " by Signet \(sheet.version)")"
        page.y += page.text(printed, size: 10)

        if hasQRCode, let modules = QRCode.modules(for: sheet.secretKey) {
            page.y += 26
            page.code(modules, x: (page.size.width - 250) / 2, y: page.y, side: 250)
            page.y += 250 + 8
            page.y += page.text(sheet.isEncrypted ? "Secret key, protected by its password" : "Secret key", size: 10, centered: true)
        }

        page.y += 26
        row(&page, "Address", sheet.address.value)
        if let publicKey = sheet.publicKey {
            page.y += 14
            if publicKey.count > RecoverySheet.lineLength {
                page.y += page.text("Public key", size: 10, weight: .semibold) + 3
                numberedLines(&page, RecoverySheet.lines(of: publicKey), firstLine: 1)
            } else {
                row(&page, "Public key", publicKey)
            }
        }
        page.y += 14
        let secretTitle = sheet.isEncrypted ? "Secret key (encrypted)" : "Secret key"
        if hasQRCode {
            row(&page, secretTitle, sheet.secretKey)
        } else {
            row(&page, secretTitle,
                partCount > 0
                    ? "Too long for one QR code. It follows as \(partCount) codes, then in full as text; keep all \(sheet.pageCount) pages together."
                    : "Too long for QR codes. It follows in full as text; keep all \(sheet.pageCount) pages together.",
                monospaced: false)
        }

        page.y += 30
        if sheet.isEncrypted {
            let label = page.layout("Password", size: 13, weight: .semibold, width: nil)
            let labelSize = page.size(of: label)
            page.draw(label, x: left, y: page.y + (44 - labelSize.height) / 2)
            g_object_unref(UnsafeMutableRawPointer(label))
            page.box(x: left + labelSize.width + 14, y: page.y, width: width - labelSize.width - 14, height: 44, thickness: 1.5)
            page.y += 44 + 6
            page.y += page.text("Write the password in by hand; it is not printed and cannot be recovered from this sheet. For more safety keep it somewhere else.", size: 10)
        } else {
            let text = "This key has no password. Anyone who sees this sheet or a copy of it controls the account."
            let height = page.measure(text, size: 12, weight: .semibold, width: width - 20)
            page.text(text, x: left + 10, y: page.y + 10, width: width - 20, size: 12, weight: .semibold)
            page.box(x: left, y: page.y, width: width, height: height + 20, thickness: 1.5)
            page.y += height + 20
        }

        // The instructions at the foot of the page.
        let footer = hasQRCode
            ? "To recover the account, open Signet, choose Scan QR code… and hold this sheet up to the camera, or choose Import account… and type the secret key\(sheet.isEncrypted ? ", then enter the password" : ""). octez-client accepts the same key. Keep this sheet offline and out of sight, and do not photograph or photocopy it."
            : "To recover the account, open Signet, choose Scan QR code… and hold up each of the \(partCount) codes on the following pages, in any order; Signet says which it still needs. Or choose Import account… and type the secret key from the last pages as one unbroken line, without the line numbers or spaces\(sheet.isEncrypted ? ". Then enter the password" : ""). octez-client accepts the typed key. Keep these pages offline and out of sight, and do not photograph or photocopy them."
        let footerHeight = page.measure(footer, size: 10, width: width)
        page.text(footer, x: left, y: max(page.y + 20, page.size.height - Self.margin - footerHeight), width: width, size: 10)
    }

    /// The small heading of a following page.
    private func continuationHeading(_ page: inout Page, number: Int) {
        page.y += page.text("Signet Tezos Wallet Recovery Sheet", size: 14, weight: .semibold) + 3
        page.y += page.text("\(sheet.alias)  ·  \(sheet.address.value)  ·  page \(number) of \(sheet.pageCount)", size: 9) + 6
        page.rule(x: Self.margin, y: page.y, width: page.contentWidth, thickness: 1)
        page.y += 1 + 14
    }

    private func drawCodes(_ page: inout Page, parts: [KeyPart], number: Int) {
        continuationHeading(&page, number: 1 + number)
        page.y += page.text("\(sheet.isEncrypted ? "Secret key (encrypted)" : "Secret key") as QR codes. Scan every part with Signet's Scan QR code, in any order.",
                            size: 10, weight: .semibold) + 18
        let side = 230.0
        for start in stride(from: 0, to: parts.count, by: 2) {
            var rowHeight = 0.0
            for (column, part) in parts[start..<min(start + 2, parts.count)].enumerated() {
                let x = Self.margin + Double(column) * (side + 27)
                guard let modules = QRCode.modules(for: part.text, correction: "L") else { continue }
                page.code(modules, x: x, y: page.y, side: side)
                let caption = page.text("Part \(part.index) of \(part.count)", x: x, y: page.y + side + 6, width: side, size: 11, weight: .semibold, centered: true)
                rowHeight = max(rowHeight, side + 6 + caption)
            }
            page.y += rowHeight + 26
        }
    }

    private func drawKey(_ page: inout Page, _ keyPage: RecoverySheet.KeyPage) {
        continuationHeading(&page, number: 1 + sheet.codePages.count + keyPage.part)
        page.y += page.text("\(sheet.isEncrypted ? "Secret key (encrypted)" : "Secret key"), lines \(keyPage.firstLine) to \(keyPage.firstLine + keyPage.lines.count - 1)",
                            size: 10, weight: .semibold) + 6
        numberedLines(&page, keyPage.lines, firstLine: keyPage.firstLine)
    }

    private func row(_ page: inout Page, _ title: String, _ value: String, monospaced: Bool = true) {
        page.y += page.text(title, size: 10, weight: .semibold) + 3
        page.y += page.text(value, size: 12, monospaced: monospaced)
    }

    /// Key text as numbered lines, so a reader typing it back can keep their place.
    private func numberedLines(_ page: inout Page, _ lines: [String], firstLine: Int) {
        for (index, line) in lines.enumerated() {
            let number = page.layout(String(format: "%02d", firstLine + index), size: 6.5, monospaced: true, width: nil)
            let text = page.layout(line, size: 8, monospaced: true, width: nil)
            // On the baseline of the line's text, right-aligned in a column 14 points wide.
            let numberSize = page.size(of: number)
            let baseline = Double(pango_layout_get_baseline(text)) / Double(PANGO_SCALE)
            let numberBaseline = Double(pango_layout_get_baseline(number)) / Double(PANGO_SCALE)
            page.draw(number, x: Self.margin + 14 - numberSize.width, y: page.y + baseline - numberBaseline)
            page.draw(text, x: Self.margin + 14 + 8, y: page.y)
            page.y += page.size(of: text).height + 1.5
            g_object_unref(UnsafeMutableRawPointer(number))
            g_object_unref(UnsafeMutableRawPointer(text))
        }
    }

    /// A page being drawn: the cairo context and how far down it has got.
    struct Page {
        let cr: OpaquePointer
        let size: CGSize
        var y = RecoverySheetPainter.margin

        var contentWidth: Double { size.width - 2 * RecoverySheetPainter.margin }

        enum Weight { case regular, semibold }

        func layout(_ text: String, size: Double, weight: Weight = .regular, monospaced: Bool = false, width: Double?) -> OpaquePointer {
            let layout = pango_cairo_create_layout(cr)!
            let font = pango_font_description_new()!
            pango_font_description_set_family(font, monospaced ? "Monospace" : "Sans")
            pango_font_description_set_weight(font, weight == .semibold ? PANGO_WEIGHT_SEMIBOLD : PANGO_WEIGHT_NORMAL)
            // In points, which are the page's units, whatever resolution Pango assumes.
            pango_font_description_set_absolute_size(font, size * Double(PANGO_SCALE))
            pango_layout_set_font_description(layout, font)
            pango_font_description_free(font)
            if let width {
                pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
                pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
            }
            pango_layout_set_text(layout, text, -1)
            return layout
        }

        func size(of layout: OpaquePointer) -> CGSize {
            var ink = PangoRectangle(), logical = PangoRectangle()
            pango_layout_get_extents(layout, &ink, &logical)
            return CGSize(width: Double(logical.width) / Double(PANGO_SCALE), height: Double(logical.height) / Double(PANGO_SCALE))
        }

        func draw(_ layout: OpaquePointer, x: Double, y: Double) {
            cairo_move_to(cr, x, y)
            pango_cairo_show_layout(cr, layout)
        }

        func measure(_ text: String, size: Double, weight: Weight = .regular, monospaced: Bool = false, width: Double) -> Double {
            let layout = layout(text, size: size, weight: weight, monospaced: monospaced, width: width)
            defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
            return self.size(of: layout).height
        }

        /// Draws wrapped text and gives its height.
        @discardableResult
        func text(_ text: String, x: Double, y: Double, width: Double, size: Double, weight: Weight = .regular,
                  monospaced: Bool = false, centered: Bool = false) -> Double {
            let layout = layout(text, size: size, weight: weight, monospaced: monospaced, width: width)
            defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
            if centered { pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER) }
            draw(layout, x: x, y: y)
            return self.size(of: layout).height
        }

        /// Text across the page at the current line.
        func text(_ text: String, size: Double, weight: Weight = .regular, monospaced: Bool = false, centered: Bool = false) -> Double {
            self.text(text, x: RecoverySheetPainter.margin, y: y, width: contentWidth, size: size, weight: weight, monospaced: monospaced, centered: centered)
        }

        func rule(x: Double, y: Double, width: Double, thickness: Double) {
            cairo_rectangle(cr, x, y, width, thickness)
            cairo_fill(cr)
        }

        func box(x: Double, y: Double, width: Double, height: Double, thickness: Double) {
            cairo_set_line_width(cr, thickness)
            cairo_rectangle(cr, x + thickness / 2, y + thickness / 2, width - thickness, height - thickness)
            cairo_stroke(cr)
        }

        /// A QR code as vectors, so it prints sharply at any size.
        func code(_ modules: [[Bool]], x: Double, y: Double, side: Double) {
            let module = side / Double(modules.count)
            for (row, line) in modules.enumerated() {
                for (column, dark) in line.enumerated() where dark {
                    cairo_rectangle(cr, x + Double(column) * module, y + Double(row) * module, module, module)
                }
            }
            cairo_fill(cr)
        }

        /// The app's icon.
        func icon(x: Double, y: Double, side: Double) {
            guard let url = Bundle.module.url(forResource: "signet-256", withExtension: "png"),
                  let surface = cairo_image_surface_create_from_png(url.path) else { return }
            defer { cairo_surface_destroy(surface) }
            let width = Double(cairo_image_surface_get_width(surface))
            guard cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS, width > 0 else { return }
            cairo_save(cr)
            cairo_translate(cr, x, y)
            cairo_scale(cr, side / width, side / width)
            cairo_set_source_surface(cr, surface, 0, 0)
            cairo_paint(cr)
            cairo_restore(cr)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Draws a recovery sheet as PDF in memory, for the tests, and prints it through GTK's print
/// dialog. Signet writes the sheet nowhere itself; what the dialog does with it (a printer, or
/// a PDF the user asks for) is the user's choice.
@MainActor
enum RecoverySheetPrinter {
    /// The sheet as PDF data, drawn as vectors so the QR code and text print sharply: one page,
    /// or more when the key has to be printed as several codes and text.
    static func pdfData(for sheet: RecoverySheet, paperSize: CGSize = CGSize(width: 595, height: 842)) -> Data {
        final class Sink { var data = Data() }
        let sink = Sink()
        let write: cairo_write_func_t = { closure, bytes, length in
            Unmanaged<Sink>.fromOpaque(closure!).takeUnretainedValue().data.append(bytes!, count: Int(length))
            return CAIRO_STATUS_SUCCESS
        }
        let surface = withExtendedLifetime(sink) {
            cairo_pdf_surface_create_for_stream(write, Unmanaged.passUnretained(sink).toOpaque(), paperSize.width, paperSize.height)!
        }
        // PDF 1.4 has no object streams, so the page objects can be counted in the bytes.
        cairo_pdf_surface_restrict_to_version(surface, CAIRO_PDF_VERSION_1_4)
        let cr = cairo_create(surface)!
        let painter = RecoverySheetPainter(sheet: sheet)
        for index in 0..<sheet.pageCount {
            painter.draw(page: index, on: cr, size: paperSize)
            cairo_show_page(cr)
        }
        cairo_destroy(cr)
        cairo_surface_finish(surface)
        cairo_surface_destroy(surface)
        return withExtendedLifetime(sink) { sink.data }
    }

    /// Shows the print dialog for the sheet over the window `widget` is in.
    static func print(_ sheet: RecoverySheet, from widget: Widget) {
        final class Job {
            let painter: RecoverySheetPainter
            init(_ painter: RecoverySheetPainter) { self.painter = painter }
        }
        let operation = gtk_print_operation_new()!
        gtk_print_operation_set_job_name(operation, "Signet recovery sheet")
        gtk_print_operation_set_n_pages(operation, Int32(sheet.pageCount))
        gtk_print_operation_set_unit(operation, GTK_UNIT_POINTS)
        // The pages carry their own margins, as upstream prints with the paper's margins at nought.
        gtk_print_operation_set_use_full_page(operation, 1)
        gtk_print_operation_set_allow_async(operation, 1)

        let job = Unmanaged.passRetained(Job(RecoverySheetPainter(sheet: sheet))).toOpaque()
        let drawPage: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, gpointer?) -> Void = { _, context, number, data in
            let job = Unmanaged<Job>.fromOpaque(data!).takeUnretainedValue()
            guard let context, let cr = gtk_print_context_get_cairo_context(context) else { return }
            let size = CGSize(width: gtk_print_context_get_width(context), height: gtk_print_context_get_height(context))
            MainActor.assumeIsolated { job.painter.draw(page: Int(number), on: cr, size: size) }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(operation), "draw-page", unsafeBitCast(drawPage, to: GCallback.self), job, { data, _ in
            Unmanaged<Job>.fromOpaque(data!).release()
        }, GConnectFlags(rawValue: 0))
        // The operation is dropped once it is done, printed or cancelled.
        let done: @convention(c) (OpaquePointer?, GtkPrintOperationResult, gpointer?) -> Void = { operation, _, _ in
            g_object_unref(UnsafeMutableRawPointer(operation))
        }
        g_signal_connect_data(UnsafeMutableRawPointer(operation), "done", unsafeBitCast(done, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))

        let window = gtk_widget_get_root(widget.pointer).map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        var error: UnsafeMutablePointer<GError>?
        _ = gtk_print_operation_run(operation, GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG, window, &error)
        if let error { g_error_free(error) }
    }
}
