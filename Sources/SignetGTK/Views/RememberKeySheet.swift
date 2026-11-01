import CAdwaita
import Foundation

/// Keeps a session-only key: writes it into the wallet directory like any other account. Offered
/// only while the selected account's key would otherwise be forgotten at quit. The GTK
/// counterpart of upstream's `Views/RememberKeySheet.swift`.
@MainActor
final class RememberKeySheet: Sheet {
    private let wallet: Wallet?
    private var isWorking = false
    private var protectToggle: Widget?
    private var passphraseField: Widget?
    private var confirmField: Widget?
    private var protectedNote: Widget?
    private var clearNote: Widget?
    private var rememberButton: Widget!

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 520)
        let directory = model.walletDirectory.map(UI.tilde) ?? "the wallet directory"
        var rows = [Form.note("This key is held in memory for this session only and would be forgotten when Signet quits. Remembering it writes it into \(directory), where it is kept like any other account and included in backups.",
                              icon: "alarm-symbolic", style: "warning-text").row]
        if isClear {
            let changed: @MainActor () -> Void = { [unowned self] in self.update() }
            let toggle = Form.toggle("Protect it with a password", isOn: model.network.isMainnet, onChange: changed)
            let passphrase = Form.password("Password", onChange: changed)
            let confirm = Form.password("Confirm password", onChange: changed)
            let protected = Form.note("The key is encrypted in octez-client's format; the password is asked for whenever the account signs.").row
            let clear = Form.note("Without a password the key is written unencrypted and anyone with access to this computer's files can use it.", style: "warning-text").row
            (protectToggle, passphraseField, confirmField, protectedNote, clearNote) = (toggle, passphrase, confirm, protected, clear)
            rows += [toggle, passphrase, confirm, protected, clear]
        } else {
            rows.append(Form.note("The key is encrypted and will be stored as it is; its password stays the same.").row)
        }
        content.setChildren([Sheet.accountTitle("Remember key", wallet: wallet).root, Form.group(rows)])
        rememberButton = button("Remember", role: .prominent, isDefault: true) { [unowned self] in self.remember() }
        update()
    }

    private var isClear: Bool { wallet?.keyKind == .unencrypted }
    private var protects: Bool { protectToggle.map(Form.isOn) ?? false }
    private var passphrase: String { passphraseField.map(Form.text) ?? "" }

    private var passphraseProblem: String? {
        guard isClear, protects else { return nil }
        if passphrase.isEmpty { return "Enter a password." }
        if passphrase.count < WalletViewModel.minimumPassphraseLength { return "Use at least \(WalletViewModel.minimumPassphraseLength) characters." }
        if confirmField.map(Form.text) != passphrase { return "The passwords do not match." }
        return nil
    }

    private func update() {
        for row in [passphraseField, confirmField, protectedNote].compactMap({ $0 }) { row.isVisible = protects }
        clearNote?.isVisible = !protects
        setBusy(isWorking ? "" : nil)
        canClose = !isWorking
        let cancel = cancelButton()
        cancel.isSensitive = !isWorking
        rememberButton.isSensitive = !isWorking && passphraseProblem == nil && wallet?.isSessionOnly == true
        setButtons([cancel, rememberButton])
    }

    private func remember() {
        guard !isWorking else { return }
        setError(nil)
        isWorking = true
        update()
        let storePassphrase = isClear && protects ? passphrase : nil
        Task {
            defer { isWorking = false; update() }
            do {
                try await model.rememberSelectedWallet(storePassphrase: storePassphrase)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() {
        passphraseField.map(Form.clear)
        confirmField.map(Form.clear)
    }
}
