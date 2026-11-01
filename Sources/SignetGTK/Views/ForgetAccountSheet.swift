import CAdwaita
import Foundation

/// Removes an account from Signet's list and key store. Everyone gets one warning; accounts whose
/// secret key Signet holds get a second, plus the password for encrypted keys. The GTK
/// counterpart of upstream's `Views/ForgetAccountSheet.swift`.
@MainActor
final class ForgetAccountSheet: Sheet {
    enum Step { case first, second }

    private var step: Step = .first
    private var isWorking = false
    private let wallet: Wallet?
    private var heading: Widget!
    private let body = UI.vbox(spacing: 0)
    private var passphraseField: Widget?

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 520)
        let header = Sheet.accountTitle("Forget account", wallet: wallet)
        heading = header.title
        content.setChildren([header.root, body])
        show()
    }

    private var holdsSecret: Bool { [.unencrypted, .encrypted].contains(wallet?.keyKind) }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var isSessionOnly: Bool { wallet?.isSessionOnly == true }
    // Upstream names `homeDirectoryForCurrentUser`, which ignores $HOME off the Mac.
    private var backupFolder: String { model.backupDirectory.map(UI.tilde) ?? "the backup folder" }
    private var passphrase: String { passphraseField.map(Form.text) ?? "" }

    private func show() {
        UI.setText(heading, step == .first ? "Forget account" : "Are you sure?")
        switch step {
        case .first: body.setChildren([firstWarning])
        case .second: body.setChildren([secondWarning])
        }
        updateButtons()
    }

    private func updateButtons() {
        setBusy(isWorking ? "" : nil)
        let cancel = cancelButton()
        cancel.isSensitive = !isWorking
        canClose = !isWorking
        switch step {
        case .first where holdsSecret:
            setButtons([cancel, button("Continue…", isDefault: true) { [unowned self] in self.step = .second; self.show() }])
        case .first:
            setButtons([cancel, button("Forget", role: .destructive, isDefault: true) { [unowned self] in self.forget() }])
        case .second:
            let forget = button("Forget for good", role: .destructive, isDefault: true) { [unowned self] in self.forget() }
            forget.isSensitive = !isWorking && !(needsPassphrase && passphrase.isEmpty)
            setButtons([cancel, forget])
        }
    }

    private var firstWarning: Widget {
        Form.group([
            Form.note(firstText, icon: "dialog-warning-symbolic", style: "warning-text").row,
            Form.note("The account itself stays on the chain with everything in it; forgetting only changes what this computer knows.").row,
        ])
    }

    private var firstText: String {
        if isSessionOnly {
            return "This is a paper key held in memory for this session only; it was never written to disk. Forgetting wipes it now. Without the key or its recovery phrase elsewhere, the account and its tez are lost."
        }
        return switch wallet?.keyKind {
        case .unencrypted, .encrypted: "Signet holds this account's secret key. Forgetting deletes that key from ~/.signet. Without another copy of the key or its recovery phrase, the account and its tez are lost."
        case .ledger: "This account's key stays on your Ledger; Signet will only forget how to reach it. You can connect it again later."
        case .remote, .unknown: "Signet will forget this account's signer entry. The key itself lives elsewhere and is not touched."
        default: "This is an address-book entry. Signet will forget the name and address; nothing else changes."
        }
    }

    private var secondWarning: Widget {
        var rows = [Form.note(isSessionOnly
            ? "Last chance. The key will be wiped from memory. Make sure you have the paper copy or the recovery phrase first."
            : "Last chance. The secret key will be deleted from this computer's wallet directory. Make sure you have exported it or have the recovery phrase first.",
            icon: "dialog-error-symbolic", style: "error-text").row]
        if !isSessionOnly {
            rows.append(Form.note("Earlier backups in \(backupFolder) may still contain this key. Delete those too if you need the key gone from this computer entirely.",
                                  icon: "drive-harddisk-symbolic").row)
        }
        if needsPassphrase, let wallet {
            let field = Form.password("Password for “\(wallet.alias)”",
                                      onChange: { [unowned self] in self.updateButtons() },
                                      onSubmit: { [unowned self] in if !self.passphrase.isEmpty { self.forget() } })
            passphraseField = field
            rows.append(field)
            rows.append(Form.note("The key is encrypted; its password is needed before it can be thrown away.").row)
            Task { @MainActor in self.focus(field) }
        }
        return Form.group(rows)
    }

    private func forget() {
        guard !isWorking else { return }
        setError(nil)
        isWorking = true
        updateButtons()
        let passphrase = needsPassphrase ? passphrase : nil
        Task {
            defer { isWorking = false; updateButtons() }
            do {
                try await model.forgetSelectedWallet(passphrase: passphrase)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() { passphraseField.map(Form.clear) }
}
