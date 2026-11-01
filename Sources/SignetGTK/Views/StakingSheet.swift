import CAdwaita
import Foundation

/// Delegation and staking for the selected wallet: delegate, change or remove the delegate;
/// stake, unstake, finalize. Each action confirms with a fee estimate (and password if needed).
/// The GTK counterpart of upstream's `Views/StakingSheet.swift`.
@MainActor
final class StakingSheet: Sheet {
    enum Mode: Equatable { case overview, chooseDelegate, amount(StakingOperationKind), confirm(StakingOperation), working(StakingOperation), done(hash: String, level: Int, StakingOperation) }
    enum StakingOperationKind { case stake, unstake }

    private var mode: Mode = .overview { didSet { render() } }
    private var bakers: [BakerCandidate] = []
    private var estimate: TransferEstimate?
    private var delegateName: String?
    /// The delegate `delegateName` was looked up for (`.task(id:)` upstream).
    private var namedDelegate: Address??
    private var workingOnDevice = false
    private let wallet: Wallet?
    private var heading: Widget!
    private let body = UI.vbox(spacing: 10)
    // Fields kept across renders, so what was typed survives a refresh.
    private var filterField: Widget!
    private let bakerList = UI.vbox(spacing: 0)
    private let pasted = UI.vbox(spacing: 0)
    private var amountField: Widget!
    private var passphraseField: Widget!
    private var feeValue: Widget?
    private var confirmButton: Widget?

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 520)
        let header = Sheet.accountTitle("Staking", wallet: wallet)
        heading = header.title
        content.setChildren([header.root, body])

        filterField = Widget(gtk_search_entry_new()!)
        PasswordEntry.setPlaceholder(filterField, "Search bakers or paste an address")
        Signals.connect(filterField, "search-changed") { [unowned self] in self.updateBakerList() }
        amountField = Form.entry("Amount (tz)", monospaced: true, onChange: { [unowned self] in self.updateButtons() },
                                 onSubmit: { [unowned self] in self.continueWithAmount() })
        passphraseField = Form.password("Password for “\(wallet?.alias ?? "")”", onChange: { [unowned self] in self.updateButtons() },
                                        onSubmit: { [unowned self] in if case .confirm(let op) = self.mode, self.canConfirm { Task { await self.perform(op) } } })

        trackers.append(Tracker { [unowned self] in
            // Read on every run, so the overview follows the model whatever mode came before.
            _ = (self.model.delegateInfo, self.model.tezBalance)
            self.lookDelegateUp()
            if self.mode == .overview { self.render() }
        })
        Task { [weak self, model] in
            let list = await model.bakers()
            guard let self else { return }
            self.bakers = list
            self.updateBakerList()
        }
    }

    private var info: DelegateInfo? { model.delegateInfo }
    private var balance: TezBalance? { model.tezBalance }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var canOperate: Bool { wallet?.keyKind.canSign == true }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var passphrase: String { Form.text(passphraseField) }
    private var canConfirm: Bool { estimate != nil && !(needsPassphrase && passphrase.isEmpty) }
    private var watchOnlyNote: String {
        switch wallet?.keyKind {
        case .remote: "Signet cannot sign for this account: it uses a remote signer."
        default: "Signet holds only this address's public key, so it can show but not change its delegation."
        }
    }

    private var title: String {
        switch mode {
        case .overview: "Staking"
        case .chooseDelegate: "Choose a baker"
        case .amount(.stake): "Stake tez"
        case .amount(.unstake): "Unstake tez"
        case .confirm(let op), .working(let op): op.title
        case .done(_, _, let op): "\(op.title): done"
        }
    }

    private func lookDelegateUp() {
        let delegate = info?.delegate
        guard namedDelegate != .some(delegate) else { return }
        namedDelegate = .some(delegate)
        delegateName = nil
        guard let delegate else { return }
        let known = model.displayName(for: delegate, indexerAlias: bakers.first { $0.address == delegate }?.alias)
        if known.isOurs || known.name != delegate.shortened() { delegateName = known.name; return }
        Task { [weak self, model] in
            let name = await model.profileName(for: delegate) ?? delegate.shortened()
            guard let self, self.namedDelegate == .some(delegate) else { return }
            self.delegateName = name
            if self.mode == .overview { self.render() }
        }
    }

    // MARK: Content

    private func render() {
        UI.setText(heading, title)
        feeValue = nil
        canClose = true
        setBusy(nil)
        switch mode {
        case .overview: body.setChildren(overview())
        case .chooseDelegate:
            body.setChildren([filterField, pasted, scrolled(bakerList, height: 300)])
            updateBakerList()
            focus(filterField)
        case .amount(let kind): body.setChildren([amountForm(kind)]); focus(amountField)
        case .confirm(let op): body.setChildren([confirmation(op)])
        case .working(let op):
            canClose = false
            body.setChildren([])
            setBusy(signsOnLedger && estimate != nil && workingOnDevice ? "\(op.title): confirm on your Ledger…" : "\(op.title)… waiting for the next block")
        case .done(let hash, let level, _):
            body.setChildren([UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                                   UI.label("Included in block \(level.formatted())", classes: ["success-icon"])]),
                              OperationLink.make(hash, network: model.network)])
        }
        updateButtons()
    }

    private func overview() -> [Widget] {
        var groups: [Widget] = []
        if !canOperate { groups.append(Form.group([Form.note(watchOnlyNote, icon: "view-reveal-symbolic").row])) }

        var delegation: [Widget] = []
        if let info {
            if info.isBaker {
                delegation.append(Form.row(UI.hbox(spacing: 8, [UI.label("👨‍🍳"), UI.label(canOperate
                    ? "This account is a baker (self-delegated). Manage it under Baking in the menu."
                    : "This address is a baker (self-delegated).", wrap: true).expand(h: true)])))
            } else if let delegate = info.delegate {
                delegation.append(Form.labeled("Delegate", content: UI.hbox(spacing: 8, [
                    AccountAvatarView(address: delegate, size: 22).root, UI.label(delegateName ?? delegate.shortened()),
                    UI.label(delegate.shortened(), classes: ["address", "dim-label"]),
                ])))
                delegation.append(Form.labeled("Accepts staking", value: info.delegateAcceptsStaking.map { $0 ? "Yes" : "No" } ?? "Unknown").row)
                let change = UI.button("Change delegate…") { [unowned self] in self.mode = .chooseDelegate }
                let remove = UI.button("Remove delegation", classes: ["destructive-action"]) { [unowned self] in self.startConfirm(.delegate(to: nil)) }
                let row = UI.hbox(spacing: 8, [change, remove])
                row.isSensitive = canOperate
                delegation.append(Form.row(row))
            } else {
                delegation.append(Form.note("Not delegated. Delegating lets a baker earn rewards with your balance; the tez never leave your account.").row)
                let button = UI.button("Delegate…") { [unowned self] in self.mode = .chooseDelegate }.align(h: GTK_ALIGN_START)
                button.isSensitive = canOperate
                delegation.append(Form.row(button))
            }
        } else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            delegation.append(Form.row(spinner.align(h: GTK_ALIGN_START)))
        }
        groups.append(section("Delegation", delegation))

        var staking: [Widget] = []
        if let balance {
            staking.append(Form.labeled("Spendable", value: AssetBalance.format(balance.spendable, symbol: "tz")).row)
            staking.append(Form.labeled("Staked", value: AssetBalance.format(balance.staked, symbol: "tz")).row)
            if balance.unstakedFrozen > 0 { staking.append(Form.labeled("Unstaking", value: AssetBalance.format(balance.unstakedFrozen, symbol: "tz")).row) }
            if balance.unstakedFinalizable > 0 { staking.append(Form.labeled("Ready to finalize", value: AssetBalance.format(balance.unstakedFinalizable, symbol: "tz")).row) }
        }
        let canStake = info?.canStake == true
        let stake = UI.button("Stake…") { [unowned self] in Form.setText(self.amountField, ""); self.mode = .amount(.stake) }
        stake.isSensitive = canStake && (balance?.spendable ?? 0) > 0
        let unstake = UI.button("Unstake…") { [unowned self] in Form.setText(self.amountField, ""); self.mode = .amount(.unstake) }
        unstake.isSensitive = (balance?.staked ?? 0) > 0
        let finalize = UI.button("Finalize") { [unowned self] in self.startConfirm(.finalizeUnstake) }
        finalize.isSensitive = (balance?.unstakedFinalizable ?? 0) > 0
        let row = UI.hbox(spacing: 8, [stake, unstake, finalize])
        row.isSensitive = canOperate
        staking.append(Form.row(row))
        staking.append(Form.note(info?.isBaker == true
            ? "Staking your own tez raises your baking power and the stake others may add. Staked tez are frozen and can be slashed. Unstaking takes a few cycles, then needs finalizing."
            : canStake
            ? "Staked tez earn more than delegated tez but are frozen and can be slashed if your baker misbehaves. Unstaking takes a few cycles, then needs finalizing."
            : "Staking needs a delegate that accepts stakers.").row)
        groups.append(section("Staking", staking))
        return groups
    }

    /// `Section(title) { … }`: a heading over a boxed list.
    private func section(_ title: String, _ rows: [Widget]) -> Widget {
        UI.vbox(spacing: 6, [UI.label(title, classes: ["heading"]), Form.group(rows)])
    }

    private func scrolled(_ child: Widget, height: Int32) -> Widget {
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, child.pointer)
        return scroller.size(height: height).classes("card")
    }

    private var bakerFilter: String { String(cString: gtk_editable_get_text(filterField.opaque)).trimmingCharacters(in: .whitespaces) }

    private var filteredBakers: [BakerCandidate] {
        let needle = bakerFilter.lowercased()
        guard !needle.isEmpty else { return bakers }
        return bakers.filter { ($0.alias?.lowercased().contains(needle) ?? false) || $0.address.value.lowercased().hasPrefix(needle) }
    }

    private func updateBakerList() {
        guard mode == .chooseDelegate else { return }
        let address = Address(bakerFilter)
        if address.isValidAccount {
            pasted.setChildren([UI.button(content: UI.hbox(spacing: 8, [AccountAvatarView(address: address, size: 24).root, UI.label("Use \(address.shortened())")])) { [unowned self] in
                self.startConfirm(.delegate(to: address))
            }.align(h: GTK_ALIGN_START)])
        } else {
            pasted.setChildren([])
        }
        if bakers.isEmpty {
            bakerList.setChildren([UI.label("No baker list for this network; paste an address above.", classes: ["dim-label"], wrap: true).margins(12)])
            return
        }
        bakerList.setChildren(filteredBakers.prefix(200).map { baker in
            let detail = "\(baker.delegators) delegators · \(baker.stakers) stakers · \(baker.acceptsStaking == true ? "accepts staking" : baker.acceptsStaking == false ? "no staking" : "")"
            let row = UI.hbox(spacing: 10, [
                AccountAvatarView(address: baker.address, size: 28).root,
                UI.vbox(spacing: 2, [UI.label(baker.alias ?? baker.address.shortened()), UI.label(detail, classes: ["dim-label", "caption"])]).expand(h: true),
                UI.label(AssetBalance.format(baker.stakingBalance, symbol: "tz"), classes: ["dim-label", "caption", "numeric"]),
            ])
            return UI.button(content: row, classes: ["flat", "suggestion"]) { [unowned self] in self.startConfirm(.delegate(to: baker.address)) }
        })
    }

    private func amountForm(_ kind: StakingOperationKind) -> Widget {
        var rows = [amountField!]
        // No Max for staking: the fee comes out of the spendable balance, so staking all of it
        // (or all but a guess at the fee) fails or leaves the account unusable. Unstaking
        // everything is fine, since the fee is paid from the spendable part.
        if kind == .unstake {
            let staked = balance?.staked ?? 0
            rows.append(Form.row(UI.button("Max") { [unowned self] in Form.setText(self.amountField, NSDecimalNumber(decimal: staked).stringValue) }.align(h: GTK_ALIGN_START)))
        }
        rows.append(Form.labeled(kind == .stake ? "Spendable" : "Staked", value: AssetBalance.format(kind == .stake ? (balance?.spendable ?? 0) : (balance?.staked ?? 0), symbol: "tz")).row)
        rows.append(Form.note(kind == .stake ? "Staked tez stay in your account but are frozen and shared in your baker's risk." : "Unstaked tez become spendable after a few cycles; come back to finalize them.").row)
        return Form.group(rows)
    }

    private func confirmation(_ op: StakingOperation) -> Widget {
        var rows = [Form.labeled("Operation", value: op.title).row]
        if case .delegate(let to) = op, let to {
            rows.append(Form.labeled("Baker", content: UI.hbox(spacing: 8, [
                AccountAvatarView(address: to, size: 22).root,
                UI.label(bakers.first { $0.address == to }?.alias ?? model.displayName(for: to, indexerAlias: nil).name),
                UI.label(to.shortened(), classes: ["address", "dim-label"]),
            ])))
        }
        if case .stake(let a) = op { rows.append(Form.labeled("Amount", value: AssetBalance.format(a, symbol: "tz")).row) }
        if case .unstake(let a) = op { rows.append(Form.labeled("Amount", value: AssetBalance.format(a, symbol: "tz")).row) }
        let fee = UI.hbox(spacing: 0)
        feeValue = fee
        updateFee()
        rows.append(Form.labeled("Fee", content: fee))
        if needsPassphrase {
            rows.append(passphraseField)
            focus(passphraseField)
        }
        if signsOnLedger { rows.append(Form.note("Your Ledger will show this operation for approval.").row) }
        return Form.group(rows)
    }

    private func updateFee() {
        guard let feeValue else { return }
        if let estimate {
            feeValue.setChildren([UI.label(AssetBalance.format(estimate.fee, symbol: "tz"))])
        } else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            feeValue.setChildren([spinner])
        }
    }

    // MARK: Buttons

    private func updateButtons() {
        switch mode {
        case .overview:
            setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        case .chooseDelegate:
            setButtons([button("Back") { [unowned self] in self.mode = .overview }])
        case .amount:
            let next = button("Continue", role: .prominent, isDefault: true) { [unowned self] in self.continueWithAmount() }
            next.isSensitive = parsedAmount != nil
            setButtons([button("Back") { [unowned self] in self.mode = .overview }, next])
        case .confirm(let op):
            let confirm = button("Confirm", role: .prominent, isDefault: true) { [unowned self] in Task { await self.perform(op) } }
            confirm.isSensitive = canConfirm
            confirmButton = confirm
            setButtons([button("Back") { [unowned self] in self.setError(nil); self.mode = .overview }, confirm])
        case .working:
            setButtons([])
        case .done:
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    private var parsedAmount: Decimal? {
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        if case .amount(.stake) = mode, value > (balance?.spendable ?? 0) { return nil }
        if case .amount(.unstake) = mode, value > (balance?.staked ?? 0) { return nil }
        return value
    }

    private func continueWithAmount() {
        guard case .amount(let kind) = mode, let amount = parsedAmount else { return }
        startConfirm(kind == .stake ? .stake(amount) : .unstake(amount))
    }

    private func startConfirm(_ op: StakingOperation) {
        setError(nil)
        estimate = nil
        mode = .confirm(op)
        Task {
            do { estimate = try await model.estimateStaking(op) } catch { setError(error.localizedDescription) }
            guard mode == .confirm(op) else { return }
            updateFee()
            updateButtons()
        }
    }

    private func perform(_ op: StakingOperation) async {
        setError(nil)
        workingOnDevice = true
        mode = .working(op)
        defer { workingOnDevice = false }
        do {
            let result = try await model.performStaking(op, limits: estimate?.limits, passphrase: needsPassphrase ? passphrase : nil)
            Form.clear(passphraseField)
            mode = .done(hash: result.hash, level: result.level, op)
        } catch {
            setError(error.localizedDescription)
            mode = .confirm(op)
        }
    }

    override func closed() { Form.clear(passphraseField) }
}
