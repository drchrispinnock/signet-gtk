import CAdwaita
import Foundation

/// Moves tez between Tezos layer 1 and the selected account on Etherlink (0.9.1): Tezos on the
/// left, Etherlink on the right, the arrow between them sets the direction. Etherlink → Tezos
/// (slow) pays out to the same account on Tezos after the rollup's challenge window. Fast
/// withdrawals are shown but not offered yet. The GTK counterpart of upstream's
/// `Views/BridgeSheet.swift`.
@MainActor
final class BridgeSheet: Sheet {
    enum Direction: Hashable { case toEtherlink, toTezos }
    enum Speed: String, CaseIterable { case fast = "Fast", slow = "Slow" }
    enum Step: Hashable { case compose, working, done(hash: String, level: Int) }

    private var direction: Direction = .toEtherlink
    private var speed: Speed = .slow
    /// The estimate and the context it was made in (S31); refreshed whenever that context moves.
    private var estimate: WalletViewModel.BridgeEstimate?
    private var estimateError: String?
    private var step: Step = .compose
    private var submitted: WalletViewModel.BridgeEstimate?
    /// What the shown estimate was asked for (`.task(id: EstimateKey)` upstream).
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?

    private let header: Widget
    private let sides = UI.hbox(spacing: 12)
    private let body = UI.vbox(spacing: 12)
    private let details = Form.group([])
    private let speedGroup: Widget
    private let passphraseGroup: Widget
    private let result = UI.vbox(spacing: 10)
    private let amountField: Widget
    private let password: PasswordField
    private let speedPicker: Widget
    private var bridgeButton: Widget!

    init(model: WalletViewModel) {
        amountField = Form.entry("Amount (tz)", monospaced: true)
        password = PasswordField(model: model, wallet: model.selectedWallet)
        speedPicker = Form.picker("Speed", options: Speed.allCases.map(\.rawValue), selected: Speed.allCases.firstIndex(of: .slow) ?? 0)
        header = Sheet.accountTitle("Bridge", wallet: model.selectedWallet).root
        speedGroup = Form.group([speedPicker])
        passphraseGroup = Form.group(password.rows)
        super.init(model: model, width: 560)
        password.onChange = { [unowned self] in self.updateButtons() }
        body.setChildren([Form.group([amountField]), details, speedGroup, passphraseGroup])
        content.setChildren([header, sides, body, result])
        Signals.connect(amountField, "changed") { [unowned self] in self.changed() }
        Signals.connect(speedPicker, "notify::selected") { [unowned self] in
            self.speed = Form.selected(self.speedPicker) == 1 ? .slow : .fast
            self.changed()
        }
        trackers.append(Tracker { [unowned self] in
            // The balances, the context and whether bridging is possible follow the model.
            _ = (self.model.tezBalance, self.model.assets, self.model.bridgeContext, self.model.canBridge)
            self.changed()
        })
        focus(amountField)
    }

    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var network: Network { submitted?.context.network ?? model.network }
    private var needsPassphrase: Bool { model.needsPassphrase(for: wallet) }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var spendable: Decimal? { model.tezBalance?.spendable }
    private var etherlink: AssetBalance? { model.assets.first { $0.kind == .etherlink } }
    private var passphrase: String { password.text }
    private var amount: Decimal? {
        if let submitted { return submitted.amount }
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0, value.isFinite else { return nil }
        return value
    }
    /// What the tez leave from: Tezos for a deposit, Etherlink for a withdrawal.
    private var sourceSpendable: Decimal? { direction == .toEtherlink ? spendable : model.etherlinkSpendable }
    private var exceedsBalance: Bool {
        guard let amount, let sourceSpendable else { return false }
        return amount + (estimate?.estimate.fee ?? 0) > sourceSpendable
    }
    private var directionAvailable: Bool {
        direction == .toEtherlink || (speed == .slow && model.canWithdrawFromEtherlink)
    }
    private var canConfirm: Bool {
        directionAvailable && amount != nil && estimate?.amount == amount && estimate?.isWithdrawal == (direction == .toTezos)
            && estimate?.context == model.bridgeContext && !exceedsBalance && model.canBridge
            && !(needsPassphrase && passphrase.isEmpty) && step == .compose
    }

    /// Something the estimate depends on may have moved: ask again if it did, and redraw.
    private func changed() {
        let key = EstimateKey(direction: direction, speed: speed, amount: Form.text(amountField), context: model.bridgeContext, step: step)
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
            sides.isVisible = true
            renderSides()
            body.isVisible = true
            renderDetails()
        case .working:
            sides.isVisible = true
            renderSides()
            setBusy(signsOnLedger ? (direction == .toEtherlink ? "Confirm the deposit on your Ledger…" : "Confirm the withdrawal on your Ledger…")
                                  : "Bridging \(AssetBalance.format(amount ?? 0, symbol: "tz")) to \(direction == .toEtherlink ? network.l2Name : "Tezos")…")
            body.isVisible = false
        case .done(let hash, let level):
            sides.isVisible = false
            body.isVisible = false
            result.setChildren(doneView(hash: hash, level: level))
        }
        updateButtons()
    }

    /// Tezos on the left, Etherlink on the right; the arrow between them is the direction.
    private func renderSides() {
        let arrow = UI.iconButton(direction == .toEtherlink ? "go-next-symbolic" : "go-previous-symbolic",
                                  tooltip: direction == .toEtherlink ? "Tezos to \(Brand.l2). Click to reverse." : "\(Brand.l2) to Tezos. Click to reverse.") { [unowned self] in
            self.direction = self.direction == .toEtherlink ? .toTezos : .toEtherlink
            self.estimate = nil
            self.changed()
        }
        arrow.classes("circular", "bridge-arrow").align(v: GTK_ALIGN_CENTER).accessibleLabel(direction == .toEtherlink ? "Direction: Tezos to \(Brand.l2)" : "Direction: \(Brand.l2) to Tezos")
        arrow.isSensitive = step == .compose
        sides.setChildren([
            side(.tezos, balance: spendable.map { AssetBalance.format($0, symbol: "tz") }, note: "spendable"),
            arrow,
            side(.etherlink, balance: etherlink.map { $0.unavailable == nil ? $0.formattedAmount : "—" }, note: "on the rollup"),
        ])
    }

    private func side(_ chain: ChainSide, balance: String?, note: String) -> Widget {
        UI.vbox(spacing: 6, [
            ChainSidePicker.logo(chain, size: 56).align(h: GTK_ALIGN_CENTER),
            UI.label(chain == .etherlink ? network.l2Name : chain.rawValue, classes: ["heading"], xalign: 0.5),
            UI.label(balance ?? "—", classes: ["numeric"], xalign: 0.5),
            UI.label(note, classes: ["dim-label", "caption"], xalign: 0.5),
        ]).classes("bridge-side").expand(h: true)
    }

    /// The rows between the amount and the password: these change as the estimate comes in and
    /// with the direction, while the fields stay where they are so typing keeps its focus.
    private func renderDetails() {
        var rows: [Widget] = []
        if exceedsBalance { rows.append(Form.note("More than the spendable balance, fee included.", style: "warning-text").row) }
        switch direction {
        case .toEtherlink:
            rows += feeRows()
            rows.append(Form.note("The tez leave this account on Tezos through \(network.l2Name)'s bridge and arrive on \(network.l2Name) under the same address within about a minute.").row)
        case .toTezos:
            switch speed {
            case .fast:
                rows.append(Form.note("Fast: a liquidity provider pays out on Tezos within about a minute for a small fee.").row)
                rows.append(Form.note("Fast withdrawals from tz accounts are not offered yet. Choose Slow.",
                                      icon: "alarm-symbolic", style: "warning-text").row)
            case .slow:
                rows += feeRows()
                rows.append(Form.note("Slow: the tez leave this account on \(network.l2Name) now and arrive on Tezos under the same address once the rollup's commitment is final, about two weeks from now.").row)
            }
        }
        if !model.canBridge {
            rows.append(Form.note("Bridging needs Layer 2 on for this network and a tz1, tz2 or tz3 account Signet can sign for.", style: "warning-text").row)
        }
        Form.setRows(details, rows)
        speedGroup.isVisible = direction == .toTezos
        passphraseGroup.isVisible = directionAvailable && wallet?.keyKind == .encrypted
    }

    /// The estimate's fee and total, or why there is none yet.
    private func feeRows() -> [Widget] {
        if let estimate = estimate?.estimate {
            return [Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row,
                    Form.labeled("Total", value: AssetBalance.format(estimate.total, symbol: "tz")).row]
        }
        guard amount != nil else { return [] }
        if let estimateError {
            let label = UI.label(estimateError, classes: ["warning-text"], wrap: true, xalign: 1)
            gtk_label_set_max_width_chars(label.opaque, 40)
            return [Form.labeled("Fee", content: label)]
        }
        let spinner = Widget(gtk_spinner_new()!)
        gtk_spinner_start(spinner.opaque)
        return [Form.labeled("Fee", content: spinner)]
    }

    private func doneView(hash: String, level: Int) -> [Widget] {
        let withdrawal = submitted?.isWithdrawal ?? (direction == .toTezos)
        let explorerNetwork = withdrawal ? (network.layer2 ?? network) : network
        let amount = AssetBalance.format(amount ?? 0, symbol: "tz")
        return [
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                 UI.label(withdrawal ? "Withdrew \(amount) from \(network.l2Name)" : "Sent \(amount) to the bridge", classes: ["success-icon", "heading"])]),
            UI.label(withdrawal
                     ? "Included in \(network.l2Name) block \(level.formatted()). The tez arrive in \(wallet?.alias ?? "the account") on Tezos once the rollup's commitment is final, about two weeks from now."
                     : "Included in block \(level.formatted()). \(network.l2Name) credits \(wallet?.alias ?? "the account") within about a minute; the \(network.l2Name) balance updates on the next refresh.",
                     classes: ["dim-label"], wrap: true),
            OperationLink.make(hash, network: explorerNetwork),
        ]
    }

    private func updateButtons() {
        switch step {
        case .compose:
            let bridge = button("Bridge", role: .prominent, isDefault: true) { [unowned self] in
                guard self.canConfirm else { return }
                Task { await self.bridge() }
            }
            bridge.isSensitive = canConfirm
            bridgeButton = bridge
            setButtons([cancelButton(), bridge])
        case .working:
            let cancel = cancelButton()
            cancel.isSensitive = false
            setButtons([cancel])
        case .done:
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    // MARK: Actions

    /// Everything the estimate depends on: a change of account, network, node, Layer 2 settings
    /// or wallet directory drops the old estimate and asks again (S31).
    private struct EstimateKey: Hashable {
        let direction: Direction
        let speed: Speed
        let amount: String
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private func refreshEstimate() async {
        guard step == .compose, directionAvailable, let amount, model.canBridge else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        render()
        do {
            let result = direction == .toEtherlink ? try await model.estimateBridgeDeposit(amount: amount) : try await model.estimateBridgeWithdrawal(amount: amount)
            if !Task.isCancelled { estimate = result }
        } catch {
            if !Task.isCancelled { estimateError = error.localizedDescription }
        }
        if !Task.isCancelled { render() }
    }

    private func bridge() async {
        guard let amount, let approved = estimate, directionAvailable else { return }
        setError(nil)
        submitted = approved
        step = .working
        render()
        do {
            let passphrase = needsPassphrase ? passphrase : nil
            let (hash, level) = approved.isWithdrawal
                ? try await model.bridgeToTezos(amount: amount, approved: approved, passphrase: passphrase)
                : try await model.bridgeToEtherlink(amount: amount, approved: approved, passphrase: passphrase)
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
