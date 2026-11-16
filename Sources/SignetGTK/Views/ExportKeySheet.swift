import CAdwaita
import Foundation

/// Shows the selected account's secret key, masked until revealed, with a copy button and a
/// warning. Encrypted keys are opened with their password first. The GTK counterpart of
/// upstream's `Views/ExportKeySheet.swift`.
@MainActor
final class ExportKeySheet: Sheet {
    private let wallet: Wallet?
    private var exported: WalletViewModel.ExportedKey?
    private var revealed = false
    private var isWorking = false
    private let form = Form.group([])
    private var passphraseField: Widget?
    private var secretLabel: Widget?

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 560)
        let warning = Sheet.banner("Anyone who has this secret key controls the account and everything in it. Never share it, never type it into a website or a chat, and keep any copy offline. Signet shows it only here and puts it on the clipboard only when you press Copy.")
        content.setChildren([Sheet.accountTitle("Export secret key", wallet: wallet).root, warning, form])
        showForm()
        if !needsPassphrase { unlock() }
    }

    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    /// The printable sheet for the key now on show.
    private var recoverySheet: RecoverySheet? {
        guard let wallet, let exported else { return nil }
        return RecoverySheet(wallet: wallet, key: exported)
    }
    private var passphrase: String { passphraseField.map(Form.text) ?? "" }

    private func showForm() {
        if let exported {
            var rows = [keyRow(title: "Secret key", value: exported.clear, maskable: true)]
            if let recoverySheet, !recoverySheet.hasQRCode {
                rows.append(Form.note("A recovery sheet for this key is \(recoverySheet.pageCount) pages: it is too long for one QR code, so it is printed as \(recoverySheet.keyParts.count) codes that Scan QR code reads back in any order, then in full as text.").row)
            } else if recoverySheet != nil {
                rows.append(Form.note(exported.encrypted == nil
                    ? "A recovery sheet is a printed page with this key as a QR code, which Scan QR code reads back in. This key has no password, so the sheet alone controls the account."
                    : "A recovery sheet is a printed page with the encrypted key as a QR code, which Scan QR code reads back in, and a box to write the password in by hand.").row)
            }
            if let encrypted = exported.encrypted {
                rows.append(keyRow(title: "Encrypted form", value: encrypted, maskable: false))
                rows.append(Form.note("The encrypted form is what ~/.signet holds; it still needs this account's password. octez-client accepts both.").row)
            }
            Form.setRows(form, rows)
        } else if needsPassphrase, let wallet {
            let field = Form.password("Password for “\(wallet.alias)”",
                                      onChange: { [unowned self] in self.updateButtons() },
                                      onSubmit: { [unowned self] in if !self.passphrase.isEmpty { self.unlock() } })
            passphraseField = field
            Form.setRows(form, [field, Form.note("The key is stored encrypted. Enter its password to decrypt and show it.").row])
            focus(field)
        }
        form.isVisible = exported != nil || needsPassphrase
        updateButtons()
    }

    private func updateButtons() {
        setBusy(isWorking ? "Decrypting…" : nil)
        if exported == nil {
            let unlock = button(needsPassphrase ? "Unlock" : "Show key", role: .prominent, isDefault: true) { [unowned self] in self.unlock() }
            unlock.isSensitive = !isWorking && !(needsPassphrase && passphrase.isEmpty)
            setButtons([cancelButton(), unlock])
        } else {
            var list: [Widget] = []
            if let recoverySheet {
                let print = button("Recovery Sheet…") { [unowned self] in RecoverySheetPrinter.print(recoverySheet, from: self.content) }
                print.tooltip(recoverySheet.hasQRCode
                              ? "Print a sheet with this key as a QR code, to recover the account later with Scan QR code"
                              : "Print this key over \(recoverySheet.pageCount) pages; it is too long for one QR code")
                list.append(print)
            }
            list.append(button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() })
            setButtons(list)
        }
    }

    private func keyRow(title: String, value: String, maskable: Bool) -> Widget {
        let label = UI.label(masked(value, maskable), classes: ["address"], wrap: true, xalign: 1)
        gtk_label_set_selectable(label.opaque, 1)
        gtk_label_set_max_width_chars(label.opaque, 36)
        // The dots stay on one line; the key itself wraps.
        gtk_label_set_wrap(label.opaque, maskable && !revealed ? 0 : 1)
        var controls = [label]
        if maskable {
            secretLabel = label
            let reveal = UI.iconButton("view-reveal-symbolic", tooltip: "Reveal") {}
            Signals.connect(reveal, "clicked") { [unowned self] in
                self.revealed.toggle()
                UI.setText(label, self.masked(value, maskable))
                gtk_label_set_wrap(label.opaque, self.revealed ? 1 : 0)
                gtk_button_set_icon_name(reveal.as(), self.revealed ? "view-conceal-symbolic" : "view-reveal-symbolic")
                reveal.tooltip(self.revealed ? "Hide" : "Reveal")
            }
            controls.append(reveal)
        }
        controls.append(UI.copyButton { value })
        return Form.labeled(title, content: UI.hbox(spacing: 8, controls))
    }

    private func masked(_ value: String, _ maskable: Bool) -> String {
        maskable && !revealed ? String(repeating: "•", count: 24) : value
    }

    private func unlock() {
        guard !isWorking else { return }
        setError(nil)
        isWorking = true
        updateButtons()
        let passphrase = needsPassphrase ? passphrase : nil
        Task {
            defer { isWorking = false; updateButtons() }
            do {
                exported = try await model.exportSecretKey(passphrase: passphrase)
                passphraseField.map(Form.clear)
                showForm()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    /// `.onDisappear { exported = nil; passphrase = "" }`: drop the key and the widgets showing it.
    override func closed() {
        exported = nil
        revealed = false
        passphraseField.map(Form.clear)
        secretLabel.map { UI.setText($0, "") }
        Form.setRows(form, [])
    }
}
