import CAdwaita
import Foundation

/// Adds an account whose key is in AirGap Vault, from the Vault's "Pair Account" code that Scan
/// QR code read. Like a Ledger account, Signet keeps only the address and public key; the
/// secret never leaves the phone, and operations are signed there (`AirGapSigning`). The GTK
/// counterpart of upstream's `Views/AddAirGapAccountSheet.swift`.
@MainActor
final class AddAirGapAccountSheet: Sheet {
    let accounts: [AirGap.Account]
    private var chosen: AirGap.Account
    private var addresses: [AirGap.Account: Address] = [:]
    private var isAdding = false
    private var lookup: Task<Void, Never>?

    private var picker: Widget?
    private var aliasField: Widget!
    private let addressBox = UI.hbox(spacing: 10)
    private let pathRow: (row: Widget, value: Widget)
    private let fingerprintRow: (row: Widget, value: Widget)
    private var addButton: Widget!

    init(model: WalletViewModel, accounts: [AirGap.Account]) {
        self.accounts = accounts
        chosen = accounts[0]
        pathRow = Form.labeled("Derivation path", value: "", monospaced: true)
        fingerprintRow = Form.labeled("Vault fingerprint", value: "", monospaced: true)
        super.init(model: model, width: 520)

        let label = accounts[0].groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        aliasField = Form.entry("Name", text: label.isEmpty ? "AirGap Vault" : label,
                                onChange: { [unowned self] in self.update() },
                                onSubmit: { [unowned self] in if self.canAdd { self.add() } })
        var rows: [Widget] = []
        if accounts.count > 1 {
            let names = accounts.map { "\($0.groupLabel.isEmpty ? "Account" : $0.groupLabel) (\($0.derivationPath))" }
            let row = Form.picker("Account", options: names) { [unowned self] in
                guard let row = self.picker else { return }
                let index = Form.selected(row)
                guard self.accounts.indices.contains(index) else { return }
                self.chosen = self.accounts[index]
                self.update()
            }
            picker = row
            rows.append(row)
        }
        rows += [aliasField, Form.labeled("Address", content: addressBox.expand(h: true)), pathRow.row, fingerprintRow.row]

        // Upstream: "… hold its signed reply up to this Mac's camera."
        content.setChildren([
            UI.hbox(spacing: 8, [UI.image(icon: "phone-symbolic", pixelSize: 20), Sheet.title("Add AirGap Vault account")]),
            Form.group(rows),
            UI.label("The secret key stays in AirGap Vault on your phone. Signet keeps only the address and public key, as it does for a Ledger. Check the address against the one the Vault shows before you use it.", classes: ["dim-label"], wrap: true),
            UI.hbox(spacing: 8, [
                UI.image(icon: "help-about-symbolic").align(v: GTK_ALIGN_START),
                UI.label("To send, Signet shows each operation as a QR code for the Vault to scan; you approve it on the phone and hold its signed reply up to this computer's camera. Signing messages for dApps or multisig proposals is not available with the Vault.", wrap: true).expand(h: true),
            ]).classes("dim-label"),
        ])
        addButton = button("Add Account", role: .prominent, isDefault: true) { [unowned self] in self.add() }
        setButtons([cancelButton(), addButton])
        trackers.append(Tracker { [weak self] in
            guard let self else { return }
            _ = self.model.wallets
            self.update()
        })

        // `.task`: the address of every account the Vault shared, derived from its public key.
        lookup = Task { [weak self, model] in
            for account in accounts {
                do {
                    let address = try await model.address(forScannedPublicKey: account.publicKey)
                    guard let self, !Task.isCancelled else { return }
                    self.addresses[account] = address
                    self.update()
                } catch {
                    self?.setError("Signet could not read the public key in the Vault's code.")
                }
            }
        }
    }

    private var address: Address? { addresses[chosen] }
    private var existing: Wallet? { address.flatMap { a in model.wallets.first { $0.address == a } } }
    private var alias: String { Form.text(aliasField) }
    private var canAdd: Bool { !alias.trimmingCharacters(in: .whitespaces).isEmpty && address != nil && existing == nil && !isAdding }

    private func update() {
        if let address {
            var lines = [UI.label(address.value, classes: ["address"], wrap: true)]
            gtk_label_set_selectable(lines[0].opaque, 1)
            if let existing {
                lines.append(UI.hbox(spacing: 4, [UI.image(icon: "object-select-symbolic", pixelSize: 12),
                                                  UI.label("Already in your list as “\(existing.alias)”", classes: ["caption"])]).classes("dim-label"))
            } else {
                lines.append(UI.label(AddressScheme.tz1.displayName, classes: ["dim-label", "caption"]))
            }
            addressBox.setChildren([AccountAvatarView(address: address, size: 32).root, UI.vbox(spacing: 2, lines).expand(h: true)])
        } else {
            addressBox.setChildren([Widget(adw_spinner_new()!).size(width: 16, height: 16)])
        }
        UI.setText(pathRow.value, chosen.derivationPath)
        UI.setText(fingerprintRow.value, chosen.masterFingerprint)
        fingerprintRow.row.isVisible = !chosen.masterFingerprint.isEmpty
        addButton.isSensitive = canAdd
    }

    private func add() {
        guard canAdd else { return }
        isAdding = true
        setError(nil)
        update()
        let alias = alias, account = chosen
        Task {
            defer { isAdding = false; update() }
            do {
                try await model.addAirGapAccount(alias: alias, account: account)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() { lookup?.cancel() }
}
