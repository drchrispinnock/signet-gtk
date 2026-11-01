import CAdwaita
import Foundation

/// Brings in an existing account from a recovery phrase or a pasted secret key. The secret is
/// derived or checked through the bridge, previewed, then written to the key store (clear, or
/// encrypted with a password like Create account), or kept in memory for this session only: a
/// paper key that is never written to disk and is forgotten when Signet quits. The GTK
/// counterpart of upstream's `Views/ImportAccountSheet.swift`.
@MainActor
final class ImportAccountSheet: Sheet {
    enum Source: String, CaseIterable, Identifiable {
        case secretKey = "Secret key"
        case phrase = "Recovery phrase"
        var id: String { rawValue }
    }

    /// Where the key goes: the wallet directory, or memory until the app quits.
    enum Keep: Hashable {
        case directory, session
    }

    private var source: Source = .secretKey
    private var keep: Keep = .directory
    private var phraseCheck: MnemonicCheck?
    private var inspected: InspectedSecretKey?
    private var preview: KeyMaterial?
    private var previewTask: Task<Void, Never>?
    private var previewError: String?
    private var isImporting = false

    private let sourcePicker = Widget(adw_toggle_group_new()!)
    private var aliasField: Widget!
    // Secret key
    private var secretKeyField: Widget!
    private var keyPassphraseField: Widget!
    private var keyPassphraseNote: Widget!
    // Phrase
    private let phraseView = Widget(gtk_text_view_new()!)
    private let phraseCheckLabel = UI.label(classes: ["caption"], wrap: true)
    private var phraseRow: Widget!
    private var legacyToggle: Widget!
    private var emailField: Widget!
    private var fundraiserPasswordField: Widget!
    private var legacyNote: Widget!
    private var phrasePassphraseField: Widget!
    private var curvePicker: Widget!
    private var accountRow: Widget!
    private var standardNote: Widget!
    // Preview and storage
    private let previewBox = UI.vbox(spacing: 2)
    private var directoryChoice: Widget!
    private var sessionNote: Widget!
    private var encryptToggle: Widget!
    private var passwordField: Widget!
    private var confirmField: Widget!
    private var passwordProblemNote: (row: Widget, label: Widget)!
    private var clearWarning: Widget!
    private var importButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 560)
        let changed: @MainActor () -> Void = { [unowned self] in self.update() }
        let refresh: @MainActor () -> Void = { [unowned self] in self.refreshPreview() }

        for source in Source.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, source.rawValue)
            adw_toggle_set_name(toggle, source.rawValue)
            adw_toggle_group_add(sourcePicker.opaque, toggle)
        }
        adw_toggle_group_set_active_name(sourcePicker.opaque, source.rawValue)
        Signals.connect(sourcePicker, "notify::active-name") { [unowned self] in
            guard let name = adw_toggle_group_get_active_name(self.sourcePicker.opaque),
                  let source = Source(rawValue: String(cString: name)), source != self.source else { return }
            self.source = source
            self.refreshPreview()
        }

        aliasField = Form.entry("Name", text: model.suggestedAlias(base: "Imported"), onChange: changed)

        secretKeyField = Form.password("Secret key (edsk… / spsk… / p2sk… / BLsk… / mdsk… / edesk…)", onChange: refresh)
        secretKeyField.classes("monospace")
        keyPassphraseField = Form.password("Password for this key", onChange: refresh)
        keyPassphraseNote = Form.note("An octez-client encrypted key. It is stored as it is and keeps this password.").row

        gtk_text_view_set_wrap_mode(phraseView.as(), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(phraseView.as(), 1)
        gtk_text_view_set_accepts_tab(phraseView.as(), 0)
        phraseView.size(height: 72).classes("phrase-editor")
        Signals.connect(Widget(OpaquePointer(gtk_text_view_get_buffer(phraseView.as())!)), "changed", refresh)
        phraseCheckLabel.isVisible = false
        phraseRow = Form.row(UI.vbox(spacing: 4, [UI.label("Recovery phrase"), phraseView, phraseCheckLabel]))
        legacyToggle = Form.toggle("Legacy fundraiser derivation (email and password)", isOn: false, onChange: refresh)
        emailField = Form.entry("Email", onChange: refresh)
        fundraiserPasswordField = Form.password("Fundraiser password", onChange: refresh)
        legacyNote = Form.note("For keys from the 2017 fundraiser and some very old wallets. Everything else uses the standard derivation below.").row
        phrasePassphraseField = Form.password("Phrase passphrase (optional)", onChange: refresh)
        curvePicker = Form.picker("Key type", options: MnemonicCurve.allCases.map(\.title), selected: 0, onChange: refresh)
        accountRow = Widget(adw_spin_row_new_with_range(0, 100, 1)!)
        adw_preferences_row_set_title(accountRow.as(), "Account")
        Signals.connect(accountRow, "notify::value") { [unowned self] in self.updateAccountTitle(); self.refreshPreview() }
        standardNote = Form.note("Temple, Kukai, Umami and most wallets use Ed25519 at account 0. If the address shown is not the one you expect, try another account or key type.").row

        let directory = UI.label("In the wallet directory")
        let session = UI.label("Only until Signet quits")
        directoryChoice = Widget(gtk_check_button_new()!)
        gtk_check_button_set_child(directoryChoice.as(), directory.pointer)
        let sessionChoice = Widget(gtk_check_button_new()!)
        gtk_check_button_set_child(sessionChoice.as(), session.pointer)
        gtk_check_button_set_group(sessionChoice.as(), directoryChoice.as())
        gtk_check_button_set_active(directoryChoice.as(), 1)
        Signals.connect(directoryChoice, "toggled") { [unowned self] in
            self.keep = gtk_check_button_get_active(self.directoryChoice.as()) != 0 ? .directory : .session
            self.update()
        }
        let keepRow = Form.labeled("Keep the key", content: UI.vbox(spacing: 4, [directoryChoice, sessionChoice]))
        sessionNote = Form.note("A paper key for one session: held in memory only, never written to the wallet directory or a backup, and gone when Signet quits (or crashes). Import it again next time.",
                                icon: "alarm-symbolic").row
        encryptToggle = Form.toggle("Encrypt with a password", isOn: model.network.isMainnet, onChange: changed)
        passwordField = Form.password("Password", onChange: changed)
        confirmField = Form.password("Confirm password", onChange: changed)
        passwordProblemNote = Form.note("")
        clearWarning = Form.note("Unencrypted keys are stored on disk unprotected. Anyone who can read ~/.signet can spend from this account.",
                                 icon: "dialog-warning-symbolic", style: "warning-text").row

        let form = Form.group([
            aliasField,
            secretKeyField, keyPassphraseField, keyPassphraseNote,
            phraseRow, legacyToggle, emailField, fundraiserPasswordField, legacyNote, phrasePassphraseField, curvePicker, accountRow, standardNote,
            Form.labeled("Address", content: previewBox),
            keepRow, sessionNote, encryptToggle, passwordField, confirmField, passwordProblemNote.row, clearWarning,
        ])
        content.setChildren([Sheet.title("Import account"), sourcePicker, form])
        importButton = button("Import", role: .prominent, isDefault: true) { [unowned self] in self.importAccount() }
        updateAccountTitle()
        update()
        focus(secretKeyField)
    }

    private var account: Int { Int(adw_spin_row_get_value(accountRow.opaque)) }
    private var derivationPath: String { "44'/1729'/\(account)'/0'" }
    private var trimmedAlias: String { Form.text(aliasField).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var encrypt: Bool { Form.isOn(encryptToggle) }
    private var password: String { Form.text(passwordField) }
    private var legacy: Bool { Form.isOn(legacyToggle) }
    private var secretKeyText: String { Form.text(secretKeyField) }
    private var curve: MnemonicCurve { MnemonicCurve.allCases[max(0, Form.selected(curvePicker))] }
    private var phrase: String {
        let buffer = gtk_text_view_get_buffer(phraseView.as())
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let text = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(text) }
        return String(cString: text)
    }
    private var existing: Wallet? { preview.flatMap { m in model.wallets.first { $0.address.value == m.address } } }
    /// An encrypted key pasted in is stored as it is; the storage password question does not apply.
    private var keepsOwnEncryption: Bool { source == .secretKey && inspected?.isEncrypted == true }
    private var passwordProblem: String? {
        guard encrypt, !keepsOwnEncryption else { return nil }
        if password.count < WalletViewModel.minimumPassphraseLength { return "Use at least \(WalletViewModel.minimumPassphraseLength) characters." }
        if password != Form.text(confirmField) { return "The passwords do not match." }
        return nil
    }
    private var canImport: Bool { preview != nil && existing == nil && !trimmedAlias.isEmpty && passwordProblem == nil && !isImporting }

    private func updateAccountTitle() {
        adw_preferences_row_set_title(accountRow.as(), "Account \(account)  (\(derivationPath))")
    }

    private func update() {
        let secret = source == .secretKey
        let encryptedKey = inspected?.isEncrypted == true || ["edesk", "spesk", "p2esk", "BLesk", "mdesk"].contains { secretKeyText.hasPrefix($0) }
        secretKeyField.isVisible = secret
        keyPassphraseField.isVisible = secret && encryptedKey
        keyPassphraseNote.isVisible = secret && encryptedKey
        phraseRow.isVisible = !secret
        legacyToggle.isVisible = !secret
        for row in [emailField!, fundraiserPasswordField!, legacyNote!] { row.isVisible = !secret && legacy }
        for row in [phrasePassphraseField!, curvePicker!, accountRow!, standardNote!] { row.isVisible = !secret && !legacy }

        if let phraseCheck, phraseCheck.wordCount > 0, !secret {
            phraseCheckLabel.isVisible = true
            phraseCheckLabel.setClass("warning-text", !phraseCheck.isValid)
            phraseCheckLabel.setClass("dim-label", phraseCheck.isValid)
            if !phraseCheck.unknownWords.isEmpty {
                UI.setText(phraseCheckLabel, "Not in the word list: \(phraseCheck.unknownWords.joined(separator: ", "))")
            } else if !phraseCheck.isValid {
                UI.setText(phraseCheckLabel, "\(phraseCheck.wordCount) words; a phrase has 12, 15, 18, 21 or 24 words and a valid checksum.")
            } else {
                UI.setText(phraseCheckLabel, "\(phraseCheck.wordCount)-word phrase")
            }
        } else {
            phraseCheckLabel.isVisible = false
        }

        updatePreviewBox()
        sessionNote.isVisible = keep == .session
        encryptToggle.isVisible = !keepsOwnEncryption
        adw_preferences_row_set_title(encryptToggle.as(), keep == .session ? "Encrypt in memory with a password" : "Encrypt with a password")
        for row in [passwordField!, confirmField!] { row.isVisible = !keepsOwnEncryption && encrypt }
        let problem = passwordProblem
        UI.setText(passwordProblemNote.label, problem ?? "")
        passwordProblemNote.row.isVisible = !keepsOwnEncryption && encrypt && problem != nil && !password.isEmpty
        clearWarning.isVisible = !keepsOwnEncryption && !encrypt && keep == .directory

        setBusy(isImporting ? "Importing…" : nil)
        canClose = !isImporting
        let cancel = cancelButton()
        cancel.isSensitive = !isImporting
        importButton.isSensitive = canImport
        setButtons([cancel, importButton])
    }

    private func updatePreviewBox() {
        if let preview {
            let address = UI.label(preview.address, classes: ["address"])
            gtk_label_set_selectable(address.opaque, 1)
            var lines = [UI.hbox(spacing: 6, [AccountAvatarView(address: Address(preview.address), size: 20).root, address]).align(h: GTK_ALIGN_END)]
            if let existing {
                lines.append(UI.label("Already in your list as “\(existing.alias)”", classes: ["warning-text", "caption"], xalign: 1))
            }
            previewBox.setChildren(lines)
        } else if let previewError {
            let label = UI.label(previewError, classes: ["warning-text"], wrap: true, xalign: 1)
            gtk_label_set_max_width_chars(label.opaque, 40)
            previewBox.setChildren([label])
        } else {
            previewBox.setChildren([UI.label("—", classes: ["dim-label"], xalign: 1)])
        }
    }

    private func refreshPreview() {
        previewTask?.cancel()
        preview = nil
        previewError = nil
        inspected = nil
        defer { update() }
        let importer = model.keyImporter
        switch source {
        case .phrase:
            let words = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { phraseCheck = nil; return }
            let (passphrase, path, curve, legacy, email, password) = (Form.text(phrasePassphraseField), derivationPath, curve, legacy, Form.text(emailField), Form.text(fundraiserPasswordField))
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                defer { if !Task.isCancelled { update() } }
                do {
                    let check = try await importer.check(mnemonic: words)
                    guard !Task.isCancelled else { return }
                    phraseCheck = check
                    guard check.isValid else { return }
                    let material = legacy
                        ? try await importer.key(fromFundraiserEmail: email, password: password, mnemonic: words)
                        : try await importer.key(fromMnemonic: words, passphrase: passphrase.isEmpty ? nil : passphrase, derivationPath: path, curve: curve)
                    guard !Task.isCancelled else { return }
                    preview = material
                } catch {
                    if !Task.isCancelled { previewError = error.localizedDescription }
                }
            }
        case .secretKey:
            let key = secretKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            let passphrase = Form.text(keyPassphraseField)
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                defer { if !Task.isCancelled { update() } }
                do {
                    let result = try await importer.inspect(secretKey: key, passphrase: passphrase.isEmpty ? nil : passphrase)
                    guard !Task.isCancelled else { return }
                    inspected = result
                    if result.needsPassphrase {
                        previewError = "Enter the key's password."
                    } else if let pk = result.publicKey, let address = result.address, let sk = result.secretKey {
                        preview = KeyMaterial(scheme: address.scheme ?? .tz1, publicKey: pk, address: address.value, secretKey: sk)
                    }
                } catch {
                    if !Task.isCancelled { previewError = error.localizedDescription }
                }
            }
        }
    }

    private func importAccount() {
        guard let preview, canImport else { return }
        setError(nil)
        isImporting = true
        update()
        let keepsOwn = keepsOwnEncryption
        let storePassphrase = (!keepsOwn && encrypt) ? password : nil
        Task {
            defer { isImporting = false; update() }
            do {
                try await model.importAccount(alias: trimmedAlias, material: preview, alreadyEncrypted: keepsOwn,
                                              storePassphrase: storePassphrase, keepForSession: keep == .session)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    /// Nothing secret stays behind in the widgets.
    override func closed() {
        previewTask?.cancel()
        preview = nil
        for field in [secretKeyField!, keyPassphraseField!, fundraiserPasswordField!, phrasePassphraseField!, passwordField!, confirmField!] { Form.clear(field) }
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(phraseView.as()), "", 0)
    }
}
