import CAdwaita
import Foundation

/// Makes the selected tz4 account's BLS proof of possession, as `octez-client create bls proof
/// for <alias>` does: the key's signature over its own public key, which a baker needs when the
/// key becomes its consensus or companion key. The proof is public; the secret key never leaves
/// the signer. Encrypted keys are opened with their password first. The GTK counterpart of
/// upstream's `Views/ProofOfPossessionSheet.swift`.
@MainActor
final class ProofOfPossessionSheet: Sheet {
    private let wallet: Wallet?
    private var proof: String?
    private var isWorking = false
    private let form = Form.group([])
    private var passphraseField: Widget?

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 560)
        let about = UI.label("A BLS proof of possession is this account's signature over its own public key. A baker needs it to make this key its consensus or companion key, and an unrevealed tz4 account's first operation carries one. It is the same proof octez-client's “create bls proof for” prints, and it can be shared freely: it proves the key is held without exposing it.",
                             classes: ["dim-label"], wrap: true)
        content.setChildren([Sheet.accountTitle("Create proof of possession", wallet: wallet).root, about, form])
        showForm()
        if !needsPassphrase { prove() }
    }

    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var passphrase: String { passphraseField.map(Form.text) ?? "" }

    private func showForm() {
        var rows: [Widget] = []
        if let publicKey = wallet?.publicKey { rows.append(valueRow(title: "Public key", value: publicKey)) }
        if let proof {
            rows.append(valueRow(title: "Proof of possession", value: proof))
        } else if needsPassphrase, let wallet {
            let field = passphraseField ?? Form.password("Password for “\(wallet.alias)”",
                                                         onChange: { [unowned self] in self.updateButtons() },
                                                         onSubmit: { [unowned self] in if !self.passphrase.isEmpty { self.prove() } })
            passphraseField = field
            rows += [field, Form.note("The key is stored encrypted. Enter its password to sign the proof.").row]
            focus(field)
        }
        Form.setRows(form, rows)
        form.isVisible = !rows.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        setBusy(isWorking ? "Signing…" : nil)
        if proof == nil {
            let create = button(needsPassphrase ? "Unlock and create" : "Create", role: .prominent, isDefault: true) { [unowned self] in self.prove() }
            create.isSensitive = !isWorking && !(needsPassphrase && passphrase.isEmpty)
            setButtons([cancelButton(), create])
        } else {
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    private func valueRow(title: String, value: String) -> Widget {
        let label = UI.label(value, classes: ["address"], wrap: true, xalign: 1)
        gtk_label_set_selectable(label.opaque, 1)
        gtk_label_set_max_width_chars(label.opaque, 36)
        return Form.labeled(title, content: UI.hbox(spacing: 8, [label, UI.copyButton { value }]))
    }

    private func prove() {
        guard let wallet, !isWorking else { return }
        setError(nil)
        isWorking = true
        updateButtons()
        let passphrase = needsPassphrase ? passphrase : nil
        Task {
            defer { isWorking = false; updateButtons() }
            do {
                proof = try await model.proofOfPossession(for: wallet, passphrase: passphrase)
                passphraseField.map(Form.clear)
                showForm()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() {
        proof = nil
        passphraseField.map(Form.clear)
    }
}
