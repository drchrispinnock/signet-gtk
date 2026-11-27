import CAdwaita
import Foundation

/// Hands a Tezos Domains name to another account (Domains tab, right-click). A second-level
/// name moves as its FA2 token, which changes the owner but not where the name points, so
/// "Point it at the new account" (on by default) first sets the record's address to the
/// recipient with `update_record`; both go in one operation group. A subdomain has no token and
/// changes owner through `update_record` alone. The record's data is kept. Goes through the
/// same approved-limits path as tokens (`TezosDomain.transferParts`, S14, S31). The GTK
/// counterpart of upstream's `Views/TransferDomainSheet.swift`.
@MainActor
final class TransferDomainSheet: Sheet {
    let domain: TezosDomain

    enum Step: Hashable { case compose, working, done(hash: String, level: Int) }

    private let to: RecipientField
    private var pointToggle: Widget!
    private var estimate: WalletViewModel.TokenTransferApproval?
    private var estimateError: String?
    private var step: Step = .compose
    private var submitted: WalletViewModel.TokenTransferApproval?
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?

    private let compose = UI.vbox(spacing: 12)
    private let pointNote: (row: Widget, label: Widget)
    private let primaryNote: Widget
    private let details = Form.group([])
    private let password: PasswordField
    private let passphraseGroup: Widget
    private let result = UI.vbox(spacing: 10)

    init(model: WalletViewModel, domain: TezosDomain) {
        self.domain = domain
        to = RecipientField(model: model, chain: model.chainService, implicitAccountsOnly: false)
        pointNote = Form.note("")
        primaryNote = Form.note("It is this account's primary name; that stops when it points elsewhere.").row
        password = PasswordField(model: model, wallet: model.selectedWallet)
        passphraseGroup = Form.group(password.rows)
        let header = Sheet.accountTitle("Transfer \(domain.name)", wallet: model.selectedWallet)
        super.init(model: model, width: 520)
        password.onChange = { [unowned self] in self.updateButtons() }
        pointToggle = Form.toggle("Point it at the new account", isOn: true) { [unowned self] in self.changed() }

        var rows = to.rows + [pointToggle!, pointNote.row]
        if isSubdomain {
            rows.append(Form.note("A subdomain has no token of its own: its record is given to the new owner directly. Its parent's owner can still change it.").row)
        }
        rows.append(primaryNote)
        compose.setChildren([Form.group(rows), details, passphraseGroup])
        content.setChildren([header.root, compose, result])

        trackers.append(Tracker { [unowned self] in
            _ = (self.to.recipient.recipient, self.to.recipient.isResolving, self.to.recipient.suggestions, self.to.recipient.errorMessage,
                 self.model.bridgeContext, self.model.canTransferDomain(domain))
            self.changed()
        })
        focus(to.entry)
    }

    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var needsPassphrase: Bool { model.needsPassphrase(for: wallet) }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var isSubdomain: Bool { domain.tokenId == nil }
    private var pointAtRecipient: Bool { pointToggle.map { Form.isOn($0) } ?? true }

    private var request: TokenTransferRequest? {
        if let submitted { return submitted.request }
        guard let owner = model.selectedWallet?.address, let to = to.recipient.recipient?.address,
              let parts = domain.transferParts(from: owner, to: to, pointAtRecipient: pointAtRecipient) else { return nil }
        let request = TokenTransferRequest(to: to, transfers: parts.transfers, records: parts.records)
        return request.isValid ? request : nil
    }
    private var canConfirm: Bool {
        guard let request, let estimate, estimate.request == request, estimate.context == model.bridgeContext else { return false }
        return step == .compose && model.canTransferDomain(domain) && !(needsPassphrase && password.text.isEmpty)
    }

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
            setBusy(signsOnLedger ? "Confirm the transfer on your Ledger…" : "Transferring \(domain.name)…")
        case .done(let hash, let level):
            compose.isVisible = false
            result.setChildren([
                UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                     UI.label("Transferred \(domain.name) to \(submitted.map { $0.request.to.shortened() } ?? "the new owner")",
                                              classes: ["success-icon", "heading"])]),
                UI.label("Included in block \(level.formatted()). Tezos Domains shows the change within a minute or so.", classes: ["dim-label"], wrap: true),
                OperationLink.make(hash, network: model.network),
            ])
        }
        updateButtons()
    }

    private func renderDetails() {
        let current = domain.address.map { $0 == model.selectedWallet?.address ? "at this account" : "where it does now" } ?? "nowhere"
        UI.setText(pointNote.label, pointAtRecipient
                   ? "\(domain.name) will resolve to the new account, so tez sent to the name go there."
                   : "\(domain.name) keeps pointing \(current) until its new owner changes it.")
        primaryNote.isVisible = domain.isReverseRecord && pointAtRecipient
        var rows: [Widget] = []
        if let estimate = estimate?.estimate {
            rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
            if estimate.burn > 0 { rows.append(Form.labeled("Storage", value: AssetBalance.format(estimate.burn, symbol: "tz")).row) }
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
        guard step == .compose, let request, model.canTransferDomain(domain) else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        render()
        do {
            let result = try await model.estimateTokenTransfer(request, on: 1)
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
            let (hash, level) = try await model.transferTokens(request, on: 1, approved: approved, passphrase: needsPassphrase ? password.text : nil)
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
