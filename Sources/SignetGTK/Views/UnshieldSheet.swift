import CAdwaita
import Foundation

/// Unshield tez: moves tez from the account's shielded wallet on the TzEL rollup to an account
/// on Tezos. The rollup proves and applies it within minutes, but the tez only reach Tezos
/// through the rollup's outbox, which the account executes here once the commitment covering
/// it is cemented (about 14 days on Shadownet). The sheet lists every withdrawal under way with
/// where it stands and an Execute button when its time has come. The GTK counterpart of
/// upstream's `Views/UnshieldSheet.swift`.
@MainActor
final class UnshieldSheet: Sheet {
    enum Step: Hashable { case compose, working, done(UnshieldReceipt) }

    private var estimate: UnshieldEstimate?
    private var estimateError: String?
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?
    private var step: Step = .compose
    private var submitted: UnshieldEstimate?
    private var execution: WithdrawalExecutionEstimate?
    private var executing: String?

    private let sides = UI.hbox(spacing: 12)
    private let compose = UI.vbox(spacing: 12)
    private let details = Form.group([])
    private let withdrawals = UI.vbox(spacing: 8)
    private let result = UI.vbox(spacing: 10)
    private let amountField: Widget
    private let recipientField: Widget
    private let thisAccount: Widget
    private let executionPassphrase: Widget
    /// The fee, password and Confirm / Cancel under a withdrawal being executed. The sheet keeps
    /// its own reference so the line survives the list being redrawn, and the password field its
    /// focus and text.
    private let confirmLine = UI.hbox(spacing: 8)
    private let executionFee = UI.label(classes: ["caption"])
    private let confirmButton = UI.button("Confirm", classes: ["suggested-action"]) {}

    init(model: WalletViewModel) {
        amountField = Form.entry("Amount (tz)", monospaced: true)
        recipientField = Form.entry("To", text: model.selectedWallet?.address.value ?? "", monospaced: true)
        thisAccount = UI.button("This account") {}
        executionPassphrase = PasswordEntry.make(placeholder: "Password for “\(model.selectedWallet?.alias ?? "")”", onChange: { _ in })
        super.init(model: model, width: 600)
        thisAccount.align(v: GTK_ALIGN_CENTER).classes("flat")
        Form.addSuffix(thisAccount, to: recipientField)
        gtk_widget_set_tooltip_text(recipientField.pointer, "tz1… or KT1…")
        executionPassphrase.size(width: 200)
        Signals.connect(thisAccount, "clicked") { [unowned self] in
            if let wallet = self.wallet { Form.setText(self.recipientField, wallet.address.value) }
        }
        Signals.connect(amountField, "changed") { [unowned self] in self.changed() }
        Signals.connect(recipientField, "changed") { [unowned self] in self.changed() }
        Signals.connect(executionPassphrase, "changed") { [unowned self] in self.updateConfirm() }
        Signals.connect(confirmButton, "clicked") { [unowned self] in
            if let execution = self.execution { Task { await self.execute(execution) } }
        }
        confirmLine.setChildren([executionFee, executionPassphrase, confirmButton,
                                 UI.button("Cancel") { [unowned self] in self.execution = nil; self.render() }])
        g_object_ref_sink(confirmLine.raw)
        compose.setChildren([Form.group([amountField, recipientField]), details, withdrawals])
        content.setChildren([Sheet.accountTitle("Unshield tez", wallet: model.selectedWallet).root, sides, compose, result])
        trackers.append(Tracker { [unowned self] in
            // Balances, the context, the withdrawals on file and the progress line follow the model.
            _ = (self.model.tezBalance, self.model.assets, self.model.shieldedWallet, self.model.bridgeContext,
                 self.model.canShield, self.model.shieldedWithdrawals, self.model.shieldProgress)
            self.changed()
        })
        focus(amountField)
    }

    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var network: Network { submitted?.context.network ?? model.network }
    private var shielded: AssetBalance? { model.assets.first { $0.kind == .shielded } }
    private var available: Decimal? { model.shieldedWallet.map { Decimal($0.availableMutez) / Mutez.perTez } }
    private var tokenIsSet: Bool { model.shieldedOperatorTokenIsSet(for: model.network) }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var amount: Decimal? {
        if let submitted { return submitted.amount }
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0, value.isFinite else { return nil }
        return value
    }
    private var trimmedRecipient: String { Form.text(recipientField).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canConfirm: Bool {
        guard let estimate, let amount else { return false }
        return estimate.amount == amount && estimate.recipient == trimmedRecipient && estimate.context == model.bridgeContext
            && model.canShield && tokenIsSet && step == .compose && executing == nil
    }

    /// Something the estimate depends on may have moved: ask again if it did, and redraw.
    private func changed() {
        let key = EstimateKey(amount: Form.text(amountField), recipient: Form.text(recipientField), context: model.bridgeContext, step: step)
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
        canClose = step != .working
        setBusy(nil)
        thisAccount.isVisible = wallet.map { Form.text(recipientField) != $0.address.value } ?? false
        switch step {
        case .compose:
            sides.isVisible = true
            renderSides()
            compose.isVisible = true
            result.isVisible = false
            renderDetails()
            renderWithdrawals()
        case .working:
            sides.isVisible = true
            renderSides()
            compose.isVisible = false
            result.isVisible = false
            setBusy(model.shieldProgress?.text ?? "Unshielding \(AssetBalance.format(amount ?? 0, symbol: "tz"))…")
        case .done(let receipt):
            sides.isVisible = false
            compose.isVisible = false
            result.setChildren(doneView(receipt))
            result.isVisible = true
        }
        updateButtons()
    }

    private func renderSides() {
        sides.setChildren([
            ShieldSheet.side(ShieldSheet.shieldLogo(size: 56), title: "Shielded", balance: shielded.map { $0.unavailable == nil ? $0.formattedAmount : "—" },
                             note: available.map { "\(AssetBalance.format($0, symbol: "tz")) available" } ?? "on the TzEL rollup"),
            ShieldSheet.arrow(tooltip: "Direction: Shielded to Tezos"),
            ShieldSheet.side(ChainSidePicker.logo(.tezos, size: 56), title: "Tezos", balance: model.tezBalance.map { AssetBalance.format($0.spendable, symbol: "tz") }, note: "spendable"),
        ])
    }

    private func renderDetails() {
        var rows: [Widget] = []
        if let estimate {
            rows.append(Form.labeled("Rollup and producer fees", value: AssetBalance.format(estimate.fees, symbol: "tz")).row)
            rows.append(Form.labeled("Spent from notes", value: "\(AssetBalance.format(Decimal(estimate.inputMutez) / Mutez.perTez, symbol: "tz")) in \(estimate.inputs.count) note\(estimate.inputs.count == 1 ? "" : "s"), \(AssetBalance.format(estimate.change, symbol: "tz")) back as change", wrap: true).row)
            rows.append(Form.labeled("Received on Tezos", value: AssetBalance.format(estimate.amount, symbol: "tz")).row)
        } else if amount != nil, !trimmedRecipient.isEmpty {
            rows.append(ShieldSheet.pendingRow("Rollup and producer fees", error: estimateError))
        }
        rows.append(Form.note("The notes are spent on the rollup within minutes; the tez reach the Tezos account only when the rollup's outbox message is executed, which is possible about 14 days later. The withdrawal stays listed here until then, with an Execute button when its time comes. The change comes back as a new note of yours.").row)
        if !model.canShield {
            rows.append(Form.note("Unshielding needs Shielded Transactions on for this network and an account Signet can sign for.", style: "warning-text").row)
        } else if !tokenIsSet {
            rows.append(Form.note("Unshielding needs the TzEL operator's access token. Enter it in Networks under Shielded Transactions.", icon: "dialog-password-symbolic", style: "warning-text").row)
        }
        Form.setRows(details, rows)
    }

    /// Every unshield of this account that is not done on Tezos yet.
    private func renderWithdrawals() {
        let list = model.shieldedWithdrawals
        if let parent = gtk_widget_get_parent(confirmLine.pointer) { gtk_box_remove(UnsafeMutableRawPointer(parent).assumingMemoryBound(to: GtkBox.self), confirmLine.pointer) }
        guard !list.isEmpty else { withdrawals.setChildren([]); withdrawals.isVisible = false; return }
        var rows = [UI.label("Withdrawals", classes: ["heading"])]
        for status in list {
            var lines = [UI.hbox(spacing: 8, [
                UI.label(AssetBalance.format(Decimal(status.withdrawal.amount) / Mutez.perTez, symbol: "tz"), classes: ["numeric"]),
                UI.label("to \(Address(status.withdrawal.recipient).shortened())", classes: ["dim-label"]),
                UI.hspacer(),
            ] + trailing(for: status)),
                UI.label(status.text, classes: ["dim-label", "caption"], wrap: true)]
            if case .executed(let hash) = status.state, let url = network.explorerURL(operation: hash) {
                lines.append(Widget(gtk_link_button_new_with_label(url.absoluteString, "View in explorer")!).align(h: GTK_ALIGN_START).classes("caption"))
            }
            if execution?.withdrawal.id == status.id, let execution, executing == nil {
                UI.setText(executionFee, "Tezos fee \(AssetBalance.format(execution.estimate.fee, symbol: "tz"))")
                executionPassphrase.isVisible = needsPassphrase
                updateConfirm()
                lines.append(confirmLine)
            }
            rows.append(UI.vbox(spacing: 4, lines))
        }
        withdrawals.setChildren(rows)
        withdrawals.isVisible = true
    }

    private func updateConfirm() {
        confirmButton.isSensitive = !(needsPassphrase && Form.text(executionPassphrase).isEmpty)
    }

    private func trailing(for status: ShieldedWithdrawalStatus) -> [Widget] {
        if executing == status.id {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            let text = signsOnLedger && model.shieldProgress == .executing ? "Confirm on your Ledger…" : model.shieldProgress?.text ?? "Executing…"
            return [spinner, UI.label(text, classes: ["dim-label", "caption"])]
        }
        switch status.state {
        case .ready:
            guard execution?.withdrawal.id != status.id else { return [] }
            let execute = UI.button("Execute…") { [unowned self] in Task { await self.prepareExecution(status.id) } }
            execute.isSensitive = executing == nil && model.canShield
            return [execute]
        case .submitted where status.withdrawal.created < Date().addingTimeInterval(-1800):
            let forget = UI.button("Forget") { [unowned self] in self.forget(status.id) }
            forget.tooltip("Drops the record and frees its notes. Only for an unshield the operator never delivered; if it lands after all, the notes show as spent on the next refresh.")
            return [forget]
        default:
            return []
        }
    }

    private func doneView(_ receipt: UnshieldReceipt) -> [Widget] {
        var rows = [
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                 UI.label("Unshielding \(AssetBalance.format(receipt.amount, symbol: "tz")) to \(Address(receipt.withdrawal.recipient).shortened())", classes: ["success-icon", "heading"])]),
            UI.label("The operator has the unshield (submission \(receipt.withdrawal.submissionID)). The rollup spends the notes once it applies it; \(AssetBalance.format(Decimal(receipt.changeMutez) / Mutez.perTez, symbol: "tz")) comes back as change. The tez reach Tezos when the outbox message is executed, about 14 days from now: open Unshield tez again then and press Execute.",
                     classes: ["dim-label"], wrap: true),
        ]
        if let hash = receipt.withdrawal.operationHash { rows.append(ShieldSheet.hashLine("Delivered in", hash: hash, network: network)) }
        return rows
    }

    private func updateButtons() {
        switch step {
        case .compose:
            let unshield = button("Unshield", role: .prominent, isDefault: true) { [unowned self] in Task { await self.unshield() } }
            unshield.isSensitive = canConfirm
            setButtons([cancelButton(), unshield])
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
        let recipient: String
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private func refreshEstimate() async {
        guard step == .compose, let amount, !trimmedRecipient.isEmpty, model.canShield else { return }
        let recipient = trimmedRecipient
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let result = try await model.estimateUnshield(amount: amount, recipient: recipient)
            if !Task.isCancelled { estimate = result }
        } catch {
            if !Task.isCancelled { estimateError = error.localizedDescription }
        }
        if !Task.isCancelled { render() }
    }

    private func unshield() async {
        guard let estimate, canConfirm else { return }
        setError(nil)
        submitted = estimate
        step = .working
        render()
        do {
            let receipt = try await model.unshieldTez(approved: estimate)
            step = .done(receipt)
        } catch {
            setError(error.localizedDescription)
            submitted = nil
            step = .compose
        }
        changed()
    }

    private func prepareExecution(_ id: String) async {
        setError(nil)
        executing = id
        render()
        do {
            execution = try await model.estimateWithdrawalExecution(id)
        } catch {
            setError(error.localizedDescription)
        }
        executing = nil
        render()
    }

    private func execute(_ approved: WithdrawalExecutionEstimate) async {
        setError(nil)
        executing = approved.withdrawal.id
        render()
        do {
            _ = try await model.executeWithdrawal(approved: approved, passphrase: needsPassphrase ? Form.text(executionPassphrase) : nil)
            execution = nil
        } catch {
            setError(error.localizedDescription)
        }
        executing = nil
        Form.clear(executionPassphrase)
        render()
    }

    private func forget(_ id: String) {
        setError(nil)
        do { try model.forgetWithdrawal(id) } catch { setError(error.localizedDescription) }
    }

    override func closed() {
        estimateTask?.cancel()
        Form.clear(executionPassphrase)
    }

    isolated deinit { g_object_unref(confirmLine.raw) }
}
