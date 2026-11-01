import CAdwaita
import Foundation

/// Deploys an octez-client generic multisig: a name, a threshold and the signers, paid for by
/// the selected account. Signers are our accounts, address-book entries, or pasted public keys
/// or tz addresses; an address is resolved to the key it has revealed on chain. The GTK
/// counterpart of upstream's `Views/CreateMultisigSheet.swift`.
@MainActor
final class CreateMultisigSheet: Sheet {
    /// One line of the signer list: where it came from and the key it resolved to.
    struct Signer: Identifiable, Equatable {
        enum Source: Equatable { case wallet(Wallet), pasted(String) }
        let source: Source
        var key: String?
        var error: String?
        var id: String {
            switch source {
            case .wallet(let w): "wallet:\(w.id)"
            case .pasted(let text): "pasted:\(text)"
            }
        }
        var title: String {
            switch source {
            case .wallet(let w): w.alias
            case .pasted(let text): WalletViewModel.isPublicKey(text) ? "Public key" : Address(text).shortened()
            }
        }
        var detail: String {
            switch source {
            case .wallet(let w): w.address.shortened()
            case .pasted(let text): String(text.prefix(14)) + "…" + String(text.suffix(6))
            }
        }
    }

    private var signers: [Signer] = [] { didSet { signersChanged() } }
    private var estimate: MultisigEstimate?
    private var estimateTask: Task<Void, Never>?
    private var isWorking = false
    private var created: MultisigContract?

    private var aliasField: Widget!
    private let signerRows = Form.group([])
    private let addRow = UI.hbox(spacing: 8)
    private var pasteEntry = Widget(gtk_entry_new()!)
    private var pasteAdd: Widget!
    private var thresholdRow: Widget!
    private var amountField: Widget!
    private var amountNote: (row: Widget, label: Widget)!
    private let estimateRows = Form.group([])
    private var passphraseField: Widget!
    private var summary: (row: Widget, label: Widget)!
    private var createButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 600)
        aliasField = Form.entry("Name (e.g. treasury)", onChange: { [unowned self] in self.updateButtons() })

        PasswordEntry.setPlaceholder(pasteEntry, "edpk…, sppk…, p2pk…, BLpk… or tz1…")
        pasteEntry.classes("monospace").expand(h: true)
        Signals.connect(pasteEntry, "changed") { [unowned self] in self.pasteAdd.isSensitive = self.pasteLooksUsable }
        Signals.connect(pasteEntry, "activate") { [unowned self] in self.addPasted() }
        pasteAdd = UI.button("Add") { [unowned self] in self.addPasted() }

        thresholdRow = Widget(adw_spin_row_new_with_range(1, 1, 1)!)
        Signals.connect(thresholdRow, "notify::value") { [unowned self] in self.thresholdChanged() }
        amountField = Form.entry("Initial balance (tz)", text: "0", monospaced: true, onChange: { [unowned self] in self.refreshEstimate() })
        amountNote = Form.note("")
        passphraseField = Form.password("Password for “\(payer?.alias ?? "")”", onChange: { [unowned self] in self.updateButtons() })
        summary = Form.note("")

        var rows: [Widget] = [thresholdRow, amountField, amountNote.row]
        if let payer {
            var paid = [AccountAvatarView(address: payer.address, size: 20).root, UI.label(payer.alias)]
            if !payer.keyKind.canSign { paid.append(UI.label("cannot sign", classes: ["error-text", "caption"])) }
            rows.append(Form.labeled("Paid by", content: UI.hbox(spacing: 8, paid)))
        }
        if needsPassphrase { rows.append(passphraseField) }
        rows.append(summary.row)

        content.setChildren([
            Sheet.title("Create multisig"),
            Form.group([aliasField]),
            UI.vbox(spacing: 6, [UI.label("Signers", classes: ["heading"]), signerRows, addRow,
                                 UI.label("An address must have revealed its public key (sent at least one operation on this network); otherwise paste the public key.", classes: ["dim-label", "caption"], wrap: true)]),
            Form.group(rows), estimateRows,
        ])
        createButton = button("Create", role: .prominent, isDefault: true) { [unowned self] in Task { await self.create() } }
        focus(aliasField)
        signersChanged()
    }

    private var payer: Wallet? { model.selectedWallet }
    private var needsPassphrase: Bool { payer?.keyKind == .encrypted }
    private var signsOnLedger: Bool { payer?.keyKind == .ledger }
    private var keys: [String] { signers.compactMap(\.key) }
    private var threshold: Int { Int(adw_spin_row_get_value(thresholdRow.opaque)) }
    /// Tez to move into the contract when it is created; `nil` when the field is not a number ≥ 0.
    private var amount: Decimal? {
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value >= 0, value.isFinite else { return nil }
        return value
    }
    private var isFunded: Bool { (amount ?? 0) > 0 }
    private var allResolved: Bool { !signers.isEmpty && signers.allSatisfy { $0.key != nil } }
    private var canCreate: Bool {
        !Form.text(aliasField).trimmingCharacters(in: .whitespaces).isEmpty && allResolved && threshold >= 1 && threshold <= keys.count
            && payer?.keyKind.canSign == true && estimate != nil && amount != nil && !(needsPassphrase && Form.text(passphraseField).isEmpty) && !isWorking
    }
    private var mine: [Wallet] { model.wallets.filter { $0.keyKind != KeyKind.none } }
    private var addressBook: [Wallet] { model.wallets.filter { $0.keyKind == KeyKind.none && !$0.address.isContract } }
    private var pasteText: String { String(cString: gtk_editable_get_text(pasteEntry.opaque)) }
    private var pasteLooksUsable: Bool {
        let t = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        return WalletViewModel.isPublicKey(t) || (Address(t).isValidAccount && !Address(t).isContract)
    }

    // MARK: Signers

    private func signersChanged() {
        Form.setRows(signerRows, signers.map(signerRow))
        signerRows.isVisible = !signers.isEmpty
        // `Stepper(in: 1...max(1, signers.count))`.
        let upper = Double(max(1, signers.count))
        adw_spin_row_set_range(thresholdRow.opaque, 1, upper)
        if adw_spin_row_get_value(thresholdRow.opaque) > upper { adw_spin_row_set_value(thresholdRow.opaque, upper) }
        if signers.count >= 2, threshold == 1, previousCount < 2 { adw_spin_row_set_value(thresholdRow.opaque, 2) }   // `@State threshold = 2`
        previousCount = signers.count
        let menu = UI.popoverMenu("Add account…", sections: [
            (mine.isEmpty ? nil : "My accounts", mine.map { w in ("\(w.alias)  \(w.address.shortened())", !isListed(w), { @MainActor [unowned self] in self.add(.wallet(w)) }) }),
            (addressBook.isEmpty ? nil : "Address book", addressBook.map { w in ("\(w.alias)  \(w.address.shortened())", !isListed(w), { @MainActor [unowned self] in self.add(.wallet(w)) }) }),
        ].filter { !$0.1.isEmpty })
        addRow.setChildren([menu, pasteEntry, pasteAdd])
        pasteAdd.isSensitive = pasteLooksUsable
        thresholdChanged()
    }

    private var previousCount = 0

    private func signerRow(_ signer: Signer) -> Widget {
        var children: [Widget] = []
        if case .wallet(let w) = signer.source { children.append(AccountAvatarView(address: w.address, size: 20).root) }
        children.append(UI.label(signer.title))
        children.append(UI.label(signer.detail, classes: ["address", "dim-label"]).expand(h: true))
        if let error = signer.error {
            let label = UI.label(error, classes: ["warning-text", "caption"], wrap: true, xalign: 1)
            gtk_label_set_lines(label.opaque, 2)
            gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(label.opaque, 30)
            children.append(label)
        } else if let key = signer.key {
            // The key that will go into the contract, checked to hash to the address shown.
            children.append(UI.label(String(key.prefix(10)) + "…", classes: ["address", "dim-label", "caption"]).tooltip(key))
        } else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            children.append(spinner)
        }
        let id = signer.id
        children.append(UI.iconButton("list-remove-symbolic", tooltip: "Remove") { [unowned self] in self.signers.removeAll { $0.id == id } })
        return Form.row(UI.hbox(spacing: 8, children))
    }

    private func isListed(_ wallet: Wallet) -> Bool {
        signers.contains { if case .wallet(let w) = $0.source { return w.id == wallet.id } else { return false } }
    }

    private func addPasted() {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasteLooksUsable, !signers.contains(where: { $0.id == "pasted:\(text)" }) else { return }
        add(.pasted(text))
        gtk_editable_set_text(pasteEntry.opaque, "")
    }

    private func add(_ source: Signer.Source) {
        let signer = Signer(source: source)
        signers.append(signer)
        Task { await resolve(signer.id) }
    }

    /// Fills in the key for one signer line: our own key, or the one the address revealed on chain.
    private func resolve(_ id: Signer.ID) async {
        guard let index = signers.firstIndex(where: { $0.id == id }) else { return }
        let text: String
        switch signers[index].source {
        case .wallet(let w): text = w.publicKey ?? w.address.value
        case .pasted(let t): text = t
        }
        do {
            let key = try await model.multisigSignerKey(from: text)
            guard let i = signers.firstIndex(where: { $0.id == id }) else { return }
            if signers.contains(where: { $0.id != id && $0.key == key }) {
                signers[i].error = "Already listed"
            } else {
                signers[i].key = key
            }
        } catch {
            guard let i = signers.firstIndex(where: { $0.id == id }) else { return }
            signers[i].error = error.localizedDescription
        }
    }

    // MARK: Estimate

    private func thresholdChanged() {
        adw_preferences_row_set_title(thresholdRow.as(), "Signatures required: \(threshold) of \(signers.count)")
        refreshEstimate()
    }

    /// `.task(id: threshold, keys, allResolved, amountText)`.
    private func refreshEstimate() {
        estimateTask?.cancel()
        estimate = nil
        setError(nil)
        updateEstimate()
        guard allResolved, threshold <= keys.count, payer?.publicKey != nil, let amount else { return }
        let (threshold, keys) = (threshold, keys)
        estimateTask = Task {
            do {
                let found = try await model.estimateCreateMultisig(threshold: threshold, keys: keys, amount: amount)
                guard !Task.isCancelled else { return }
                estimate = found
            } catch {
                guard !Task.isCancelled else { return }
                setError(error.localizedDescription)
            }
            updateEstimate()
        }
    }

    private func updateEstimate() {
        if amount == nil {
            UI.setText(amountNote.label, "Enter a number of tez, 0 or more.")
            amountNote.label.setClass("warning-text", true)
        } else {
            UI.setText(amountNote.label, "Moved into the contract from the paying account as it is created. 0 leaves it empty; it can be sent tez at any time.")
            amountNote.label.setClass("warning-text", false)
        }
        UI.setText(summary.label, "The contract holds tez; spending needs \(threshold) of the \(signers.count) signers. octez-client recognises it as a multisig too.")
        var rows: [Widget] = []
        if let estimate {
            rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
            rows.append(Form.labeled("Storage", value: AssetBalance.format(estimate.burn, symbol: "tz")).row)
            if let amount, amount > 0 {
                rows.append(Form.labeled("Total", value: AssetBalance.format(estimate.fee + estimate.burn + amount, symbol: "tz")).row)
            }
        } else if allResolved, threshold <= keys.count, amount != nil {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            rows.append(Form.labeled("Fee", content: spinner))
        }
        Form.setRows(estimateRows, rows)
        estimateRows.isVisible = !rows.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        guard created == nil else { return }
        setBusy(isWorking ? (signsOnLedger ? "Confirm the origination on your Ledger…" : "Deploying…") : nil)
        canClose = !isWorking
        let cancel = cancelButton()
        cancel.isSensitive = !isWorking
        createButton.isSensitive = canCreate
        setButtons([cancel, createButton])
    }

    private func create() async {
        guard canCreate else { return }
        setError(nil)
        isWorking = true
        updateButtons()
        defer { isWorking = false; updateButtons() }
        do {
            let contract = try await model.createMultisig(alias: Form.text(aliasField), threshold: threshold, keys: keys, amount: amount ?? 0,
                                                          limits: estimate?.limits, passphrase: needsPassphrase ? Form.text(passphraseField) : nil)
            created = contract
            showDone(contract)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func showDone(_ contract: MultisigContract) {
        setBusy(nil)
        canClose = true
        let address = UI.label(contract.address.value, classes: ["address"])
        gtk_label_set_selectable(address.opaque, 1)
        content.setChildren([
            Sheet.title("Create multisig"),
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"), UI.label("“\(contract.alias)” is deployed", classes: ["success-icon"])]),
            UI.hbox(spacing: 8, [address, UI.copyButton(tooltip: "Copy address") { contract.address.value }]),
            UI.label(isFunded
                     ? "It was created holding \(AssetBalance.format(amount ?? 0, symbol: "tz")). Give the other signers the address so they can add it on their side."
                     : "Send tez to that address to fund it. Give the other signers the address so they can add it on their side.",
                     classes: ["dim-label"], wrap: true),
        ])
        setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
    }

    override func closed() {
        estimateTask?.cancel()
        Form.clear(passphraseField)
    }
}
