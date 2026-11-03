import CAdwaita
import Foundation

/// Shield tez: moves tez from the selected account on Tezos into the account's shielded wallet
/// on the TzEL rollup. Two steps run back to back: a layer 1 deposit to the bridge ticketer
/// (an ordinary approved, signed transaction into a deposit pool only this wallet can claim),
/// then the shield itself (a note to ourselves, proved by the proving service and relayed by
/// the operator, which takes a minute or two). A deposit whose shield did not finish stays
/// listed as a pool to shield again. The GTK counterpart of upstream's `Views/ShieldSheet.swift`.
@MainActor
final class ShieldSheet: Sheet {
    enum Step: Hashable { case compose, working, done(ShieldReceipt) }

    private var pool: DepositPool?
    private var prepareError: String?
    private var estimate: ShieldEstimate?
    private var estimateError: String?
    private var step: Step = .compose
    private var submitted: ShieldEstimate?
    private var shieldingPool: String?
    private var prepareKey: PrepareKey?
    private var prepareTask: Task<Void, Never>?
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?

    private let sides = UI.hbox(spacing: 12)
    private let compose = UI.vbox(spacing: 12)
    private let details = Form.group([])
    private let passphraseGroup: Widget
    private let pending = UI.vbox(spacing: 6)
    private let result = UI.vbox(spacing: 10)
    private let amountField: Widget
    private let passphraseField: Widget

    init(model: WalletViewModel) {
        amountField = Form.entry("Amount (tz)", monospaced: true)
        passphraseField = Form.password("Password for “\(model.selectedWallet?.alias ?? "")”")
        passphraseGroup = Form.group([passphraseField])
        super.init(model: model, width: 560)
        compose.setChildren([Form.group([amountField]), details, passphraseGroup, pending])
        content.setChildren([Sheet.accountTitle("Shield tez", wallet: model.selectedWallet).root, sides, compose, result])
        Signals.connect(amountField, "changed") { [unowned self] in self.changed() }
        Signals.connect(passphraseField, "changed") { [unowned self] in self.updateButtons() }
        trackers.append(Tracker { [unowned self] in
            // Balances, the context, the pools on file and the progress line follow the model.
            _ = (self.model.tezBalance, self.model.assets, self.model.bridgeContext, self.model.canShield,
                 self.model.shieldedPools, self.model.shieldProgress)
            self.changed()
        })
        focus(amountField)
    }

    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var network: Network { submitted?.context.network ?? model.network }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var spendable: Decimal? { model.tezBalance?.spendable }
    private var shielded: AssetBalance? { model.assets.first { $0.kind == .shielded } }
    private var tokenIsSet: Bool { model.shieldedOperatorTokenIsSet(for: model.network) }
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
    /// The deposit must cover the rollup's and the producer's fees with something left over.
    private var tooSmall: Bool {
        guard let estimate else { return false }
        return estimate.shieldedAmount <= 0
    }
    private var canConfirm: Bool {
        amount != nil && estimate?.amount == amount && estimate?.context == model.bridgeContext && pool != nil
            && !exceedsBalance && !tooSmall && model.canShield && tokenIsSet
            && !(needsPassphrase && passphrase.isEmpty) && step == .compose && shieldingPool == nil
    }

    /// Something the pool or the estimate depends on may have moved: ask again if it did
    /// (`.task(id:)` upstream), and redraw.
    private func changed() {
        let prepare = PrepareKey(context: model.bridgeContext, step: step)
        if prepare != prepareKey {
            prepareKey = prepare
            prepareTask?.cancel()
            pool = nil
            prepareError = nil
            prepareTask = Task { await self.prepare() }
        }
        let key = EstimateKey(amount: Form.text(amountField), pool: pool?.pubkeyHash, context: model.bridgeContext, step: step)
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
        switch step {
        case .compose:
            sides.isVisible = true
            renderSides()
            compose.isVisible = true
            result.isVisible = false
            renderDetails()
            renderPending()
        case .working:
            sides.isVisible = true
            renderSides()
            compose.isVisible = false
            result.isVisible = false
            setBusy(signsOnLedger && model.shieldProgress == .depositing
                    ? "Confirm the deposit on your Ledger…"
                    : model.shieldProgress?.text ?? "Shielding \(AssetBalance.format(amount ?? 0, symbol: "tz"))…")
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
            Self.side(ChainSidePicker.logo(.tezos, size: 56), title: "Tezos", balance: spendable.map { AssetBalance.format($0, symbol: "tz") }, note: "spendable"),
            Self.arrow(tooltip: "Direction: Tezos to Shielded"),
            Self.side(Self.shieldLogo(size: 56), title: "Shielded", balance: shielded.map { $0.unavailable == nil ? $0.formattedAmount : "—" }, note: "on the TzEL rollup"),
        ])
    }

    private func renderDetails() {
        var rows: [Widget] = []
        if exceedsBalance { rows.append(Form.note("More than the spendable balance, fee included.", style: "warning-text").row) }
        if let estimate {
            rows.append(Form.labeled("Tezos fee", value: AssetBalance.format(estimate.estimate.fee, symbol: "tz")).row)
            rows.append(Form.labeled("Rollup and producer fees", value: AssetBalance.format(Decimal(estimate.rollupFeeMutez + estimate.producerFeeMutez) / Mutez.perTez, symbol: "tz")).row)
            rows.append(Form.labeled("Shielded", value: AssetBalance.format(estimate.shieldedAmount, symbol: "tz")).row)
            if tooSmall { rows.append(Form.note("The deposit must be more than the rollup's and the producer's fees.", style: "warning-text").row) }
        } else if amount != nil, pool != nil {
            rows.append(Self.pendingRow("Tezos fee", error: estimateError))
        }
        if let prepareError {
            rows.append(Form.note(prepareError, style: "warning-text").row)
        } else if pool == nil, model.canShield {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            rows.append(Form.row(UI.hbox(spacing: 6, [spinner, UI.label(model.shieldProgress?.text ?? "Preparing…", classes: ["dim-label"])])))
        }
        rows.append(Form.note("The tez leave this account on Tezos into a deposit pool on the TzEL rollup that only this wallet can claim, and are then shielded into a note of yours. The rollup's fee is set at shield time; the shielded amount can differ slightly if it changes.").row)
        if !model.canShield {
            rows.append(Form.note("Shielding needs Shielded Transactions on for this network and an account Signet can sign for.", style: "warning-text").row)
        } else if !tokenIsSet {
            rows.append(Form.note("Shielding needs the TzEL operator's access token. Enter it in Networks under Shielded Transactions.", icon: "dialog-password-symbolic", style: "warning-text").row)
        }
        Form.setRows(details, rows)
        passphraseGroup.isVisible = needsPassphrase
    }

    /// Deposits already on the rollup whose shield has not happened yet.
    private func renderPending() {
        let pools = model.shieldedPools.filter { $0.pool.operationHash != nil && $0.pool.shieldedCm == nil }
        guard !pools.isEmpty else { pending.setChildren([]); pending.isVisible = false; return }
        var rows = [UI.label("Deposits waiting to be shielded", classes: ["heading"])]
        for status in pools {
            var line = [
                UI.label(status.balance.map { AssetBalance.format($0, symbol: "tz") } ?? "not credited yet", classes: ["numeric"]),
                UI.label(status.pool.pubkeyHash.prefix(12) + "…", classes: ["monospace", "dim-label", "caption"]),
                UI.hspacer(),
            ]
            if shieldingPool == status.id {
                let spinner = Widget(gtk_spinner_new()!)
                gtk_spinner_start(spinner.opaque)
                line += [spinner, UI.label(model.shieldProgress?.text ?? "Shielding…", classes: ["dim-label", "caption"])]
            } else {
                let shield = UI.button("Shield") { [unowned self] in Task { await self.shield(pool: status.id) } }
                shield.isSensitive = shieldingPool == nil && tokenIsSet && (status.balanceMutez ?? 0) != 0
                line.append(shield)
            }
            rows.append(UI.hbox(spacing: 8, line))
        }
        pending.setChildren(rows)
        pending.isVisible = true
    }

    private func doneView(_ receipt: ShieldReceipt) -> [Widget] {
        var rows = [
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                 UI.label("Shielded \(AssetBalance.format(receipt.shielded, symbol: "tz"))", classes: ["success-icon", "heading"])]),
            UI.label("The operator has delivered the shield to the rollup (fees: \(AssetBalance.format(Decimal(receipt.rollupFeeMutez) / Mutez.perTez, symbol: "tz")) rollup, \(AssetBalance.format(Decimal(receipt.producerFeeMutez) / Mutez.perTez, symbol: "tz")) producer). The Shielded balance shows the note once the rollup has applied it, on the next refresh.",
                     classes: ["dim-label"], wrap: true),
        ]
        if let hash = receipt.depositHash { rows.append(Self.hashLine("Deposit", hash: hash, network: network)) }
        if let hash = receipt.operationHash { rows.append(Self.hashLine("Shield", hash: hash, network: network)) }
        return rows
    }

    private func updateButtons() {
        switch step {
        case .compose:
            let shield = button("Shield", role: .prominent, isDefault: true) { [unowned self] in Task { await self.shield() } }
            shield.isSensitive = canConfirm
            setButtons([cancelButton(), shield])
        case .working:
            let cancel = cancelButton()
            cancel.isSensitive = false
            setButtons([cancel])
        case .done:
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    // MARK: Shared by the shielded sheets

    static func shieldLogo(size: Int32) -> Widget {
        UI.resourceImage("shield", "png", pixelSize: size) ?? UI.label("Shielded", classes: ["caption"])
    }

    /// One side of the move: its logo, name, balance and a line about it.
    static func side(_ logo: Widget, title: String, balance: String?, note: String) -> Widget {
        UI.vbox(spacing: 6, [
            logo.align(h: GTK_ALIGN_CENTER),
            UI.label(title, classes: ["heading"], xalign: 0.5),
            UI.label(balance ?? "—", classes: ["numeric"], xalign: 0.5),
            UI.label(note, classes: ["dim-label", "caption"], xalign: 0.5),
        ]).classes("bridge-side").expand(h: true)
    }

    /// The arrow between the sides; the direction is fixed in these sheets.
    static func arrow(tooltip: String) -> Widget {
        UI.circle(UI.image(icon: "go-next-symbolic", pixelSize: 20), size: 40, classes: "shield-arrow")
            .align(v: GTK_ALIGN_CENTER).accessibleLabel(tooltip)
    }

    /// A figure still on its way: a spinner, or why it could not be had.
    static func pendingRow(_ title: String, error: String?) -> Widget {
        if let error {
            let label = UI.label(error, classes: ["warning-text"], wrap: true, xalign: 1)
            gtk_label_set_max_width_chars(label.opaque, 40)
            return Form.labeled(title, content: label)
        }
        let spinner = Widget(gtk_spinner_new()!)
        gtk_spinner_start(spinner.opaque)
        return Form.labeled(title, content: spinner)
    }

    /// "Deposit  oo7…  View in explorer".
    static func hashLine(_ title: String, hash: String, network: Network) -> Widget {
        let value = UI.label(hash, classes: ["monospace"])
        gtk_label_set_ellipsize(value.opaque, PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_selectable(value.opaque, 1)
        var line = [UI.label(title, classes: ["dim-label"]), value.expand(h: true)]
        if let url = network.explorerURL(operation: hash) {
            let link = Widget(gtk_link_button_new_with_label(url.absoluteString, "View in explorer")!)
            line.append(link)
        }
        return UI.hbox(spacing: 8, line)
    }

    // MARK: Actions

    private struct PrepareKey: Hashable {
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private struct EstimateKey: Hashable {
        let amount: String
        let pool: String?
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    /// Checks the rollup and reserves the pool the deposit will go to, once per context.
    private func prepare() async {
        guard step == .compose, model.canShield else { return }
        do {
            let reserved = try await model.prepareShield()
            if !Task.isCancelled { pool = reserved }
        } catch {
            if !Task.isCancelled { prepareError = error.localizedDescription }
        }
        if !Task.isCancelled { changed() }
    }

    private func refreshEstimate() async {
        guard step == .compose, let amount, let pool, model.canShield else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let result = try await model.estimateShield(amount: amount, pool: pool)
            if !Task.isCancelled { estimate = result }
        } catch {
            if !Task.isCancelled { estimateError = error.localizedDescription }
        }
        if !Task.isCancelled { render() }
    }

    private func shield() async {
        guard let estimate, canConfirm else { return }
        setError(nil)
        submitted = estimate
        step = .working
        render()
        do {
            let receipt = try await model.shieldTez(approved: estimate, passphrase: needsPassphrase ? passphrase : nil)
            step = .done(receipt)
        } catch {
            setError(error.localizedDescription)
            submitted = nil
            step = .compose
        }
        Form.clear(passphraseField)
        changed()
    }

    /// Shields a deposit that is already on the rollup.
    private func shield(pool pubkeyHash: String) async {
        setError(nil)
        shieldingPool = pubkeyHash
        render()
        do {
            let receipt = try await model.shieldPool(pubkeyHash)
            step = .done(receipt)
        } catch {
            setError(error.localizedDescription)
        }
        shieldingPool = nil
        changed()
    }

    override func closed() {
        prepareTask?.cancel()
        estimateTask?.cancel()
        Form.clear(passphraseField)
    }
}
