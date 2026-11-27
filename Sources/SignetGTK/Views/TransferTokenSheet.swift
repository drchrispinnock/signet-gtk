import CAdwaita
import Foundation

/// Transfers a fungible token from the Assets tab: an amount in the token's own units (or Max,
/// the exact balance), the recipient (an address, a `.tez` name or one of our accounts, as in
/// Send), the fee and storage burn from the estimate, then the result. FA2 and FA1.2 tokens go
/// through the same approved-limits path as NFTs (`TokenTransferRequest`, S14), bound to the
/// account, network and directory the estimate was made in (S31). The GTK counterpart of
/// upstream's `Views/TransferTokenSheet.swift`.
@MainActor
final class TransferTokenSheet: Sheet {
    let token: AssetBalance

    enum Step: Hashable { case compose, working, done(hash: String, level: Int) }

    private let to: RecipientField
    private var estimate: WalletViewModel.TokenTransferApproval?
    private var estimateError: String?
    private var step: Step = .compose
    private var submitted: WalletViewModel.TokenTransferApproval?
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?

    private let compose = UI.vbox(spacing: 12)
    private let amountField: Widget
    private let amountProblem: (row: Widget, label: Widget)
    private let details = Form.group([])
    private let password: PasswordField
    private let passphraseGroup: Widget
    private let result = UI.vbox(spacing: 10)

    init(model: WalletViewModel, token: AssetBalance) {
        self.token = token
        let chain = token.layer == 2 ? (model.layer2Chain ?? model.chainService) : model.chainService
        to = RecipientField(model: model, chain: chain, implicitAccountsOnly: token.layer == 2)
        let symbol = token.symbol.isEmpty ? token.name : token.symbol
        amountField = Form.entry("Amount (\(symbol))", monospaced: true)
        amountProblem = Form.note("", style: "warning-text")
        password = PasswordField(model: model, wallet: model.selectedWallet)
        passphraseGroup = Form.group(password.rows)
        let header = Sheet.accountTitle("Transfer \(symbol)\(token.isLayer2 ? " on \(Brand.l2)" : "")", wallet: model.selectedWallet)
        super.init(model: model, width: 520)
        password.onChange = { [unowned self] in self.updateButtons() }

        let max = UI.button("Max", classes: ["flat"]) {}
        max.align(v: GTK_ALIGN_CENTER)
        Form.addSuffix(max, to: amountField)
        Signals.connect(max, "clicked") { [unowned self] in
            Form.setText(self.amountField, AssetBalance.plainAmount(raw: token.rawAmount ?? "0", decimals: token.decimals))
        }
        Signals.connect(amountField, "changed") { [unowned self] in self.changed() }
        let balance = UI.label("Balance \(token.formattedAmount)", classes: ["dim-label", "numeric"])
        compose.setChildren([Form.group([amountField, amountProblem.row] + to.rows), details, passphraseGroup])
        content.setChildren([header.root, balance, compose, result])

        trackers.append(Tracker { [unowned self] in
            // The recipient, the context and whether the account can sign follow their models.
            _ = (self.to.recipient.recipient, self.to.recipient.isResolving, self.to.recipient.suggestions, self.to.recipient.errorMessage,
                 self.model.bridgeContext, self.model.canTransferToken(token))
            self.changed()
        })
        focus(amountField)
    }

    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var network: Network { model.tokenNetwork(on: token.layer) }
    private var needsPassphrase: Bool { model.needsPassphrase(for: wallet) }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var symbol: String { token.symbol.isEmpty ? token.name : token.symbol }
    private var amountText: String { Form.text(amountField) }

    /// The amount typed, in the token's smallest unit, when it is sound and within the balance.
    private var rawAmount: String? {
        guard let raw = TokenTransfer.rawAmount(from: amountText, decimals: token.decimals), let balance = token.rawAmount,
              TokenTransfer.nat(raw, isAtMost: balance) else { return nil }
        return raw
    }
    private var exceedsBalance: Bool {
        guard let raw = TokenTransfer.rawAmount(from: amountText, decimals: token.decimals), let balance = token.rawAmount else { return false }
        return !TokenTransfer.nat(raw, isAtMost: balance)
    }
    private var request: TokenTransferRequest? {
        if let submitted { return submitted.request }
        guard let to = to.recipient.recipient?.address, let rawAmount, let transfer = TokenTransfer(token: token, rawAmount: rawAmount) else { return nil }
        let request = TokenTransferRequest(to: to, transfers: [transfer])
        return request.isValid ? request : nil
    }
    private var canConfirm: Bool {
        guard let request, let estimate, estimate.request == request, estimate.context == model.bridgeContext else { return false }
        return step == .compose && model.canTransferToken(token) && !(needsPassphrase && password.text.isEmpty)
    }

    /// Something the estimate depends on may have moved: ask again if it did, and redraw.
    private func changed() {
        let key = EstimateKey(request: request, context: model.bridgeContext, step: step)
        if key != estimateKey {
            estimateKey = key
            estimateTask?.cancel()
            estimate = nil
            estimateError = nil
            estimateTask = Task { await refreshEstimate() }
        }
        render()
    }

    // MARK: Content

    private func render() {
        setBusy(nil)
        canClose = step != .working
        if case .done = step { result.isVisible = true } else { result.isVisible = false }
        switch step {
        case .compose:
            compose.isVisible = true
            to.render()
            renderDetails()
        case .working:
            compose.isVisible = false
            setBusy(signsOnLedger ? "Confirm the transfer on your Ledger…" : "Transferring \(amountText) \(symbol)…")
        case .done(let hash, let level):
            compose.isVisible = false
            result.setChildren([
                UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                     UI.label("Transferred \(amountText) \(symbol) to \(submitted.map { $0.request.to.shortened() } ?? "the recipient")",
                                              classes: ["success-icon", "heading"])]),
                UI.label("Included in block \(level.formatted()). The Assets tab updates on the next refresh.", classes: ["dim-label"], wrap: true),
                OperationLink.make(hash, network: network),
            ])
        }
        updateButtons()
    }

    private func renderDetails() {
        if exceedsBalance {
            UI.setText(amountProblem.label, "More than the balance.")
            amountProblem.row.isVisible = true
        } else if !amountText.isEmpty, TokenTransfer.rawAmount(from: amountText, decimals: token.decimals) == nil {
            UI.setText(amountProblem.label, token.decimals == 0 ? "A whole number." : "A number with at most \(token.decimals) decimal places.")
            amountProblem.row.isVisible = true
        } else {
            amountProblem.row.isVisible = false
        }
        var rows: [Widget] = []
        if let estimate = estimate?.estimate {
            rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
            if estimate.burn > 0 {
                rows.append(Form.labeled("Storage", value: AssetBalance.format(estimate.burn, symbol: "tz")).row
                    .tooltip("The token's ledger grows for a recipient that has not held it before; the chain charges for the space."))
            }
        } else if request != nil {
            if let estimateError {
                let label = UI.label(estimateError, classes: ["warning-text"], wrap: true, xalign: 1)
                gtk_label_set_max_width_chars(label.opaque, 40)
                rows.append(Form.labeled("Fee", content: label))
            } else {
                let spinner = Widget(gtk_spinner_new()!)
                gtk_spinner_start(spinner.opaque)
                rows.append(Form.labeled("Fee", content: spinner))
            }
        }
        if !model.canTransferToken(token) {
            rows.append(Form.note(token.layer == 2 ? "Transfers on \(Brand.l2) need Layer 2 on and a tz1, tz2 or tz3 account Signet can sign for." : "Signet cannot sign for this account.",
                                  style: "warning-text").row)
        }
        Form.setRows(details, rows)
        details.isVisible = !rows.isEmpty
        passphraseGroup.isVisible = wallet?.keyKind == .encrypted
    }

    private func updateButtons() {
        switch step {
        case .compose:
            let confirm = button("Transfer", role: .prominent, isDefault: true) { [unowned self] in
                guard self.canConfirm else { return }
                Task { await self.send() }
            }
            confirm.isSensitive = canConfirm
            setButtons([cancelButton(), confirm])
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
        let request: TokenTransferRequest?
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private func refreshEstimate() async {
        guard step == .compose, let request, model.canTransferToken(token) else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        render()
        do {
            let result = try await model.estimateTokenTransfer(request, on: token.layer)
            if !Task.isCancelled { estimate = result }
        } catch {
            if !Task.isCancelled { estimateError = error.localizedDescription }
        }
        if !Task.isCancelled { render() }
    }

    private func send() async {
        guard let request, let approved = estimate else { return }
        setError(nil)
        submitted = approved
        step = .working
        render()
        do {
            let (hash, level) = try await model.transferTokens(request, on: token.layer, approved: approved, passphrase: needsPassphrase ? password.text : nil)
            password.clear()
            step = .done(hash: hash, level: level)
        } catch {
            setError(error.localizedDescription)
            submitted = nil
            step = .compose
        }
        render()
    }

    override func closed() {
        estimateTask?.cancel()
        password.clear()
    }
}
