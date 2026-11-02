import CAdwaita
import Foundation

/// Moves tez between Tezos layer 1 and the selected account on Etherlink (0.9.1): Tezos on the
/// left, Etherlink on the right, the arrow between them sets the direction. Only layer 1 →
/// Etherlink can be carried out today: Etherlink does not yet offer withdrawals from
/// Michelson-interface (tz) accounts, so that direction, with its Fast / Slow choice, is shown
/// but cannot be confirmed. The GTK counterpart of upstream's `Views/BridgeSheet.swift`.
@MainActor
final class BridgeSheet: Sheet {
    enum Direction: Hashable { case toEtherlink, toTezos }
    enum Speed: String, CaseIterable { case fast = "Fast", slow = "Slow" }
    enum Step: Hashable { case compose, working, done(hash: String, level: Int) }

    private var direction: Direction = .toEtherlink
    private var speed: Speed = .fast
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
    private let passphraseField: Widget
    private let speedPicker: Widget
    private var bridgeButton: Widget!

    init(model: WalletViewModel) {
        amountField = Form.entry("Amount (tz)", monospaced: true)
        passphraseField = Form.password("Password for “\(model.selectedWallet?.alias ?? "")”")
        speedPicker = Form.picker("Speed", options: Speed.allCases.map(\.rawValue))
        header = Sheet.accountTitle("Bridge", wallet: model.selectedWallet).root
        speedGroup = Form.group([speedPicker])
        passphraseGroup = Form.group([passphraseField])
        super.init(model: model, width: 560)
        body.setChildren([Form.group([amountField]), details, speedGroup, passphraseGroup])
        content.setChildren([header, sides, body, result])
        Signals.connect(amountField, "changed") { [unowned self] in self.changed() }
        Signals.connect(passphraseField, "changed") { [unowned self] in self.updateButtons() }
        Signals.connect(speedPicker, "notify::selected") { [unowned self] in
            self.speed = Form.selected(self.speedPicker) == 1 ? .slow : .fast
            self.render()
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
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var spendable: Decimal? { model.tezBalance?.spendable }
    private var etherlink: AssetBalance? { model.assets.first { $0.kind == .etherlink } }
    private var passphrase: String { Form.text(passphraseField) }
    private var amount: Decimal? {
        if let submitted { return submitted.amount }
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0, value.isFinite else { return nil }
        return value
    }
    private var exceedsBalance: Bool {
        guard let amount, let spendable else { return false }
        return amount + (estimate?.estimate.fee ?? 0) > spendable
    }
    private var canConfirm: Bool {
        direction == .toEtherlink && amount != nil && estimate?.amount == amount
            && estimate?.context == model.bridgeContext && !exceedsBalance && model.canBridge
            && !(needsPassphrase && passphrase.isEmpty) && step == .compose
    }

    /// Something the estimate depends on may have moved: ask again if it did, and redraw.
    private func changed() {
        let key = EstimateKey(direction: direction, amount: Form.text(amountField), context: model.bridgeContext, step: step)
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
        switch step {
        case .compose:
            sides.isVisible = true
            renderSides()
            body.isVisible = true
            renderDetails()
        case .working:
            sides.isVisible = true
            renderSides()
            setBusy(signsOnLedger ? "Confirm the deposit on your Ledger…" : "Bridging \(AssetBalance.format(amount ?? 0, symbol: "tz")) to Etherlink…")
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
                                  tooltip: direction == .toEtherlink ? "Tezos to Etherlink. Click to reverse." : "Etherlink to Tezos. Click to reverse.") { [unowned self] in
            self.direction = self.direction == .toEtherlink ? .toTezos : .toEtherlink
            self.estimate = nil
            self.changed()
        }
        arrow.classes("circular", "bridge-arrow").align(v: GTK_ALIGN_CENTER).accessibleLabel(direction == .toEtherlink ? "Direction: Tezos to Etherlink" : "Direction: Etherlink to Tezos")
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
            UI.label(chain.rawValue, classes: ["heading"], xalign: 0.5),
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
            if let estimate = estimate?.estimate {
                rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
                rows.append(Form.labeled("Total", value: AssetBalance.format(estimate.total, symbol: "tz")).row)
            } else if amount != nil {
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
            rows.append(Form.note("The tez leave this account on Tezos through Etherlink's bridge and arrive on Etherlink under the same address within about a minute.").row)
        case .toTezos:
            rows.append(Form.note(speed == .fast
                ? "Fast: a liquidity provider pays out on Tezos within about a minute for a small fee."
                : "Slow: the tez arrive on Tezos after the rollup's 15-day withdrawal period, with no fee.").row)
            rows.append(Form.note("Etherlink does not yet offer withdrawals from accounts on its Michelson interface (tz addresses). This direction will work once it does.",
                                  icon: "alarm-symbolic", style: "warning-text").row)
        }
        if !model.canBridge {
            rows.append(Form.note("Bridging needs Layer 2 on for this network and a tz1, tz2 or tz3 account Signet can sign for.", style: "warning-text").row)
        }
        Form.setRows(details, rows)
        speedGroup.isVisible = direction == .toTezos
        passphraseGroup.isVisible = direction == .toEtherlink && needsPassphrase
    }

    private func doneView(hash: String, level: Int) -> [Widget] {
        [
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                 UI.label("Sent \(AssetBalance.format(amount ?? 0, symbol: "tz")) to the bridge", classes: ["success-icon", "heading"])]),
            UI.label("Included in block \(level.formatted()). Etherlink credits \(wallet?.alias ?? "the account") within about a minute; the Etherlink balance updates on the next refresh.",
                     classes: ["dim-label"], wrap: true),
            OperationLink.make(hash, network: network),
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
        let amount: String
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private func refreshEstimate() async {
        guard step == .compose, direction == .toEtherlink, let amount, model.canBridge else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        render()
        do {
            let result = try await model.estimateBridgeDeposit(amount: amount)
            if !Task.isCancelled { estimate = result }
        } catch {
            if !Task.isCancelled { estimateError = error.localizedDescription }
        }
        if !Task.isCancelled { render() }
    }

    private func bridge() async {
        guard let amount, let approved = estimate, direction == .toEtherlink else { return }
        setError(nil)
        submitted = approved
        step = .working
        render()
        do {
            let (hash, level) = try await model.bridgeToEtherlink(amount: amount, approved: approved, passphrase: needsPassphrase ? passphrase : nil)
            Form.clear(passphraseField)
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
        Form.clear(passphraseField)
    }
}
