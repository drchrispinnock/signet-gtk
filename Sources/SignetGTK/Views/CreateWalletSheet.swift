import CAdwaita
import Foundation

/// Names a new wallet and picks its key type, then generates and stores the key. The GTK
/// counterpart of upstream's `Views/CreateWalletSheet.swift`.
@MainActor
final class CreateWalletSheet: Sheet {
    private let schemes = AddressScheme.allCases.filter(\.isSupported)
    private var aliasField: Widget!
    private var schemePicker: Widget!
    private var caveat: (row: Widget, label: Widget)!
    private var encryptToggle: Widget!
    private var passwordField: Widget!
    private var confirmField: Widget!
    private var passwordProblemNote: (row: Widget, label: Widget)!
    private var passwordNote: Widget!
    private var clearWarning: Widget!
    private var createButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 480)
        let changed: @MainActor () -> Void = { [unowned self] in self.update() }
        let submit: @MainActor () -> Void = { [unowned self] in if self.canCreate { self.create() } }
        aliasField = Form.entry("Name", text: model.suggestedAlias(), onChange: changed, onSubmit: submit)
        schemePicker = Form.picker("Key type", options: schemes.map { option in
            option == .tz1 ? "\(option.rawValue) · \(option.displayName) (recommended)" : "\(option.rawValue) · \(option.displayName)"
        }, selected: schemes.firstIndex(of: .tz1) ?? 0, onChange: changed)
        caveat = Form.note("", icon: "help-about-symbolic")
        // Real money defaults to encrypted; testnets default to convenience.
        encryptToggle = Form.toggle("Encrypt with a password", isOn: model.network.isMainnet, onChange: changed)
        passwordField = Form.password("Password", onChange: changed, onSubmit: submit)
        confirmField = Form.password("Confirm password", onChange: changed, onSubmit: submit)
        passwordProblemNote = Form.note("")
        passwordNote = Form.note("You will be asked for this password every time the key signs. It cannot be recovered; if you lose it the key is lost.").row
        clearWarning = Form.note("Unencrypted keys are stored on disk unprotected. Anyone who can read ~/.signet can spend from this account.",
                                 icon: "dialog-warning-symbolic", style: "warning-text").row
        let saved = Form.note("The key is saved to ~/.signet in octez-client's format, so octez-client can use it too.").row
        let form = Form.group([aliasField, schemePicker, caveat.row, encryptToggle, passwordField, confirmField,
                               passwordProblemNote.row, passwordNote, clearWarning, saved])
        content.setChildren([Sheet.title("Create account"), form])

        createButton = button("Create", role: .prominent, isDefault: true) { [unowned self] in self.create() }
        setButtons([cancelButton(), createButton])
        focus(aliasField)
        trackers.append(Tracker { [unowned self] in self.update() })
    }

    private var scheme: AddressScheme { schemes[max(0, Form.selected(schemePicker))] }
    private var encrypt: Bool { Form.isOn(encryptToggle) }
    private var password: String { Form.text(passwordField) }
    private var trimmedAlias: String { Form.text(aliasField).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var passwordProblem: String? {
        guard encrypt else { return nil }
        if password.count < WalletViewModel.minimumPassphraseLength { return "Use at least \(WalletViewModel.minimumPassphraseLength) characters." }
        if password != Form.text(confirmField) { return "The passwords do not match." }
        return nil
    }
    private var canCreate: Bool { !trimmedAlias.isEmpty && scheme.isSupported && !model.isCreatingWallet && passwordProblem == nil }

    private func update() {
        let caveatText = scheme.caveat
        UI.setText(caveat.label, caveatText ?? "")
        caveat.row.isVisible = caveatText != nil
        for row in [passwordField!, confirmField!, passwordNote!] { row.isVisible = encrypt }
        clearWarning.isVisible = !encrypt
        let problem = passwordProblem
        UI.setText(passwordProblemNote.label, problem ?? "")
        passwordProblemNote.row.isVisible = encrypt && problem != nil && !password.isEmpty
        createButton.isSensitive = canCreate
        setBusy(model.isCreatingWallet ? "Generating key…" : nil)
    }

    private func create() {
        setError(nil)
        let alias = trimmedAlias, scheme = scheme, passphrase = encrypt ? password : nil
        Task {
            do {
                try await model.createWallet(alias: alias, scheme: scheme, passphrase: passphrase)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() {
        Form.clear(passwordField)
        Form.clear(confirmField)
    }
}
