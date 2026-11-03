import CAdwaita
import Foundation

/// Send shielded: a private transfer from the account's shielded wallet to someone else's
/// shielded address, with an optional memo only they can read. The recipient is a payment
/// address, a JSON record another wallet printed (Signet's "Shielded address…" or the tzel
/// CLI's `receive`), pasted here or picked from the address book; the fingerprint shown is
/// what the two of you compare. The rollup applies the transfer within minutes; the recipient
/// sees the note on their next scan. The GTK counterpart of upstream's
/// `Views/SendShieldedSheet.swift`.
@MainActor
final class SendShieldedSheet: Sheet {
    enum Step: Hashable { case compose, working, done(SendShieldedReceipt) }
    private static let pasted = "pasted"

    private var contacts: [ShieldedContact] = []
    private var chosen = SendShieldedSheet.pasted
    private var parsed: ShieldedContact?
    private var parseError: String?
    private var parseTask: Task<Void, Never>?
    private var estimate: SendShieldedEstimate?
    private var estimateError: String?
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?
    private var step: Step = .compose
    private var submitted: SendShieldedEstimate?

    private let subtitle = UI.label(classes: ["dim-label"])
    private let compose = UI.vbox(spacing: 12)
    private let recipientGroup = Form.group([])
    private var recipientPicker: Widget!
    private let pasteBox = ShieldedJSONEditor(placeholder: "Paste the recipient's shielded address (the JSON their wallet printed)", height: 90)
    private let pasteRow: Widget
    private let saveName = Widget(gtk_entry_new()!)
    private let saveRow: Widget
    private let saveButton = UI.button("Save") {}
    private let amountField: Widget
    private let memoField: Widget
    private let details = Form.group([])
    private let sent = UI.vbox(spacing: 6)
    private let result = UI.vbox(spacing: 10)

    init(model: WalletViewModel) {
        pasteRow = Form.row(pasteBox.root)
        amountField = Form.entry("Amount (tz)", monospaced: true)
        memoField = Form.entry("Memo")
        saveRow = Form.row(UI.hbox(spacing: 8, [saveName.size(width: 240), saveButton]))
        super.init(model: model, width: 620)
        // The account and, once known, its shielded figures on one line under the title.
        var column = [Sheet.title("Send shielded")]
        var line: [Widget] = []
        if let wallet = model.selectedWallet { line.append(UI.label("\(wallet.alias)  \(wallet.address.shortened())", classes: ["dim-label"])) }
        line.append(subtitle)
        column.append(UI.hbox(spacing: 0, line))
        var row: [Widget] = []
        if let wallet = model.selectedWallet { row.append(AccountAvatarView(address: wallet.address, size: 40).root) }
        row.append(UI.vbox(spacing: 2, column).align(v: GTK_ALIGN_CENTER))
        let header = UI.hbox(spacing: 12, row)
        PasswordEntry.setPlaceholder(saveName, "Name for the address book")
        Signals.connect(saveName, "changed") { [unowned self] in self.renderRecipient() }
        Signals.connect(saveButton, "clicked") { [unowned self] in if let parsed = self.parsed { self.save(parsed) } }
        gtk_widget_set_tooltip_text(memoField.pointer, "Optional, only the recipient can read it")
        pasteBox.onChange = { [unowned self] in self.parsePasted() }
        Signals.connect(amountField, "changed") { [unowned self] in self.changed() }
        Signals.connect(memoField, "changed") { [unowned self] in self.changed() }
        recipientPicker = Form.picker("To", options: []) { [unowned self] in
            let index = Form.selected(self.recipientPicker)
            self.chosen = self.contacts.indices.contains(index) ? self.contacts[index].fingerprint : Self.pasted
            self.renderRecipient()
            self.changed()
        }
        compose.setChildren([recipientGroup, Form.group([amountField, memoField]), details, sent])
        content.setChildren([header, compose, result])
        reloadContacts(choosing: nil)
        trackers.append(Tracker { [unowned self] in
            // Balances, the context, the records of earlier transfers and the progress line.
            _ = (self.model.assets, self.model.shieldedWallet, self.model.bridgeContext, self.model.canShield,
                 self.model.shieldedTransfers, self.model.shieldProgress)
            self.changed()
        })
    }

    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var shielded: AssetBalance? { model.assets.first { $0.kind == .shielded } }
    private var available: Decimal? { model.shieldedWallet.map { Decimal($0.availableMutez) / Mutez.perTez } }
    private var tokenIsSet: Bool { model.shieldedOperatorTokenIsSet(for: model.network) }
    private var memo: String { Form.text(memoField) }
    private var amount: Decimal? {
        if let submitted { return submitted.amount }
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0, value.isFinite else { return nil }
        return value
    }
    /// The recipient in use: a contact, or what was pasted once it parses.
    private var recipient: ShieldedContact? {
        if chosen == Self.pasted { return parsed }
        return contacts.first { $0.fingerprint == chosen }
    }
    private var canConfirm: Bool {
        guard let estimate, let amount, let recipient else { return false }
        return estimate.amount == amount && estimate.recipient.fingerprint == recipient.fingerprint && estimate.memo == memo && estimate.context == model.bridgeContext
            && model.canShield && tokenIsSet && step == .compose
    }

    static func short(_ fingerprint: String) -> String {
        fingerprint.count > 20 ? "\(fingerprint.prefix(12))…\(fingerprint.suffix(6))" : fingerprint
    }

    /// Something the estimate depends on may have moved: ask again if it did, and redraw.
    private func changed() {
        let key = EstimateKey(amount: Form.text(amountField), recipient: recipient?.fingerprint, memo: memo, context: model.bridgeContext, step: step)
        if key != estimateKey {
            estimateKey = key
            estimateTask?.cancel()
            estimate = nil
            estimateError = nil
            estimateTask = Task { await refreshEstimate() }
        }
        render()
    }

    // MARK: Pieces

    private func render() {
        if let shielded, shielded.unavailable == nil {
            UI.setText(subtitle, "  ·  \(shielded.formattedAmount) shielded\(available.map { ", \(AssetBalance.format($0, symbol: "tz")) available" } ?? "")")
            subtitle.isVisible = true
        } else {
            subtitle.isVisible = false
        }
        canClose = step != .working
        setBusy(nil)
        switch step {
        case .compose:
            compose.isVisible = true
            result.isVisible = false
            renderDetails()
            renderSent()
        case .working:
            compose.isVisible = false
            result.isVisible = false
            setBusy(model.shieldProgress?.text ?? "Sending \(AssetBalance.format(amount ?? 0, symbol: "tz"))…")
        case .done(let receipt):
            compose.isVisible = false
            result.setChildren(doneView(receipt))
            result.isVisible = true
        }
        updateButtons()
    }

    private func reloadContacts(choosing fingerprint: String?) {
        contacts = (try? model.shieldedContacts()) ?? []
        if let fingerprint { chosen = fingerprint } else if let first = contacts.first, chosen == Self.pasted, parsed == nil { chosen = first.fingerprint }
        let options = contacts.map { "\($0.name)  \(Self.short($0.fingerprint))" } + ["A pasted shielded address…"]
        Form.setOptions(recipientPicker, options, selected: contacts.firstIndex { $0.fingerprint == chosen } ?? contacts.count)
        renderRecipient()
    }

    private func renderRecipient() {
        var rows = [recipientPicker!]
        if chosen == Self.pasted {
            rows.append(pasteRow)
            if let parseError, !pasteBox.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(Form.note(parseError, style: "warning-text").row)
            } else if let parsed {
                rows.append(Form.labeled("Fingerprint", value: Self.short(parsed.fingerprint), monospaced: true).row)
                if parsed.name.isEmpty {
                    rows.append(saveRow)
                    let name = String(cString: gtk_editable_get_text(saveName.opaque))
                    saveButton.isSensitive = !name.trimmingCharacters(in: .whitespaces).isEmpty
                } else {
                    rows.append(Form.note("Already in the address book as “\(parsed.name)”.").row)
                }
            }
        } else if let recipient {
            rows.append(Form.labeled("Fingerprint", value: Self.short(recipient.fingerprint), monospaced: true).row)
        }
        Form.setRows(recipientGroup, rows)
    }

    private func renderDetails() {
        var rows: [Widget] = []
        if let estimate {
            rows.append(Form.labeled("Rollup and producer fees", value: AssetBalance.format(estimate.fees, symbol: "tz")).row)
            rows.append(Form.labeled("Spent from notes", value: "\(AssetBalance.format(Decimal(estimate.inputMutez) / Mutez.perTez, symbol: "tz")) in \(estimate.inputs.count) note\(estimate.inputs.count == 1 ? "" : "s"), \(AssetBalance.format(estimate.change, symbol: "tz")) back as change", wrap: true).row)
        } else if amount != nil, recipient != nil {
            rows.append(ShieldSheet.pendingRow("Rollup and producer fees", error: estimateError))
        }
        rows.append(Form.note("Nothing on the rollup names the recipient: only their viewing keys find the note. Compare the fingerprint with them before sending; a note sent to the wrong address cannot be recovered. The change comes back as a new note of yours.").row)
        if !model.canShield {
            rows.append(Form.note("Sending needs Shielded Transactions on for this network and an account Signet can sign for.", style: "warning-text").row)
        } else if !tokenIsSet {
            rows.append(Form.note("Sending needs the TzEL operator's access token. Enter it in Networks under Shielded Transactions.", icon: "dialog-password-symbolic", style: "warning-text").row)
        }
        Form.setRows(details, rows)
    }

    /// Transfers of this account the rollup has not applied yet, and recent ones.
    private func renderSent() {
        let list = model.shieldedTransfers
        guard !list.isEmpty else { sent.setChildren([]); sent.isVisible = false; return }
        var rows = [UI.label("Sent", classes: ["heading"])]
        for transfer in list {
            var line = [
                UI.label(AssetBalance.format(Decimal(transfer.amount) / Mutez.perTez, symbol: "tz"), classes: ["numeric"]),
                UI.label("to \(transfer.recipientName ?? Self.short(transfer.recipientFingerprint))", classes: ["dim-label"]),
                UI.hspacer(),
                UI.label(transfer.applied ? "Applied by the rollup" : "With the operator", classes: ["dim-label", "caption"]),
            ]
            if !transfer.applied, transfer.created < Date().addingTimeInterval(-1800) {
                let forget = UI.button("Forget") { [unowned self] in
                    self.setError(nil)
                    do { try self.model.forgetTransfer(transfer.id) } catch { self.setError(error.localizedDescription) }
                }
                forget.tooltip("Drops the record and frees its notes. Only for a transfer the operator never delivered; if it lands after all, the notes show as spent on the next refresh.")
                line.append(forget)
            }
            rows.append(UI.hbox(spacing: 8, line))
        }
        sent.setChildren(rows)
        sent.isVisible = true
    }

    private func doneView(_ receipt: SendShieldedReceipt) -> [Widget] {
        var rows = [
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                 UI.label("Sent \(AssetBalance.format(receipt.amount, symbol: "tz")) to \(receipt.transfer.recipientName ?? Self.short(receipt.transfer.recipientFingerprint))", classes: ["success-icon", "heading"])]),
            UI.label("The operator has the transfer (submission \(receipt.transfer.submissionID)). The rollup spends your notes once it applies it, and the recipient finds theirs on their next scan.",
                     classes: ["dim-label"], wrap: true),
        ]
        if let hash = receipt.transfer.operationHash {
            rows.append(ShieldSheet.hashLine("Delivered in", hash: hash, network: model.network))
        }
        return rows
    }

    private func updateButtons() {
        switch step {
        case .compose:
            let send = button("Send", role: .prominent, isDefault: true) { [unowned self] in Task { await self.send() } }
            send.isSensitive = canConfirm
            setButtons([cancelButton(), send])
        case .working:
            let cancel = cancelButton()
            cancel.isSensitive = false
            setButtons([cancel])
        case .done:
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    // MARK: Actions

    private struct EstimateKey: Hashable {
        let amount: String
        let recipient: String?
        let memo: String
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private func parsePasted() {
        parseTask?.cancel()
        parsed = nil
        parseError = nil
        renderRecipient()
        changed()
        let json = pasteBox.text
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parseTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let contact = try await model.shieldedRecipient(from: json)
                if !Task.isCancelled { parsed = contact }
            } catch {
                if !Task.isCancelled { parseError = error.localizedDescription }
            }
            if !Task.isCancelled { renderRecipient(); changed() }
        }
    }

    private func save(_ contact: ShieldedContact) {
        setError(nil)
        do {
            try model.addShieldedContact(contact, name: String(cString: gtk_editable_get_text(saveName.opaque)))
            gtk_editable_set_text(saveName.opaque, "")
            reloadContacts(choosing: contact.fingerprint)
            changed()
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func refreshEstimate() async {
        guard step == .compose, let amount, let recipient, model.canShield else { return }
        let memo = memo
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let result = try await model.estimateSendShielded(amount: amount, recipient: recipient, memo: memo)
            if !Task.isCancelled { estimate = result }
        } catch {
            if !Task.isCancelled { estimateError = error.localizedDescription }
        }
        if !Task.isCancelled { render() }
    }

    private func send() async {
        guard let estimate, canConfirm else { return }
        setError(nil)
        submitted = estimate
        step = .working
        render()
        do {
            let receipt = try await model.sendShielded(approved: estimate)
            step = .done(receipt)
        } catch {
            setError(error.localizedDescription)
            submitted = nil
            step = .compose
        }
        changed()
    }

    override func closed() {
        parseTask?.cancel()
        estimateTask?.cancel()
    }
}
