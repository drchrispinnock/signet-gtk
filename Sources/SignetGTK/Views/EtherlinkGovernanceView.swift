import CAdwaita
import Foundation

/// The Etherlink tab of Governance: the current period of the slow or fast kernel-upgrade
/// process, the proposals to upvote (or a new kernel hash to propose) in a Proposal period,
/// and Yea / Nay / Pass on the candidate in a Promotion period. Every call is a layer 1
/// transaction with a fee, so the confirm step shows the estimate and sends with exactly it.
/// The GTK counterpart of upstream's `Views/EtherlinkGovernanceView.swift`; the sheet's
/// buttons, error line and status are `GovernanceSheet`'s, set while this tab is shown.
@MainActor
final class EtherlinkGovernanceView {
    enum Mode: Equatable {
        case overview
        case confirm(EtherlinkGovernance.Operation)
        case working(EtherlinkGovernance.Operation)
        case done(hash: String, level: Int, EtherlinkGovernance.Operation)
    }

    let model: WalletViewModel
    let root = UI.vbox(spacing: 16)
    private unowned let sheet: Sheet
    private var process: EtherlinkGovernance.Process = .slow
    private var mode: Mode = .overview { didSet { render() } }
    private var state: EtherlinkGovernance.State?
    private var loadError: String?
    private var estimate: WalletViewModel.EtherlinkGovernanceEstimate?
    private var estimateError: String?
    private var loadTask: Task<Void, Never>?
    /// Bumped for every confirm step, so a late estimate for an earlier one is dropped.
    private var confirmation = 0
    private let processPicker: Widget
    private let heading = UI.label(classes: ["heading"])
    private let body = UI.vbox(spacing: 12)
    private let newHashField: Widget
    private let passphraseField: Widget
    private var hashProblem: Widget?
    private var typedButtons: [Widget] = []
    private var feeValue: Widget?

    init(model: WalletViewModel, sheet: Sheet) {
        self.model = model
        self.sheet = sheet
        processPicker = Widget(adw_toggle_group_new()!)
        newHashField = Form.entry("Propose or upvote a kernel hash (0x…)", monospaced: true)
        passphraseField = Form.password("Password for “\(model.selectedWallet?.alias ?? "")”")
        let processes = model.network.etherlinkGovernanceProcesses
        for candidate in processes {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, candidate.title)
            adw_toggle_set_name(toggle, candidate.rawValue)
            adw_toggle_group_add(processPicker.opaque, toggle)
        }
        // `.onAppear { if !processes.contains(process) … }`.
        if !processes.contains(process), let first = processes.first { process = first }
        adw_toggle_group_set_active_name(processPicker.opaque, process.rawValue)
        Signals.connect(processPicker, "notify::active-name") { [unowned self] in
            guard let name = adw_toggle_group_get_active_name(self.processPicker.opaque),
                  let chosen = EtherlinkGovernance.Process(rawValue: String(cString: name)), chosen != self.process else { return }
            self.process = chosen
            self.reload()
        }
        Signals.connect(newHashField, "changed") { [unowned self] in self.updateTyped() }
        Signals.connect(passphraseField, "changed") { [unowned self] in self.updateButtons() }
        root.setChildren([processPicker, heading, body])
        reload()
    }

    private var wallet: Wallet? { model.selectedWallet }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }

    private var title: String {
        switch mode {
        case .overview: process.title
        case .confirm(let op), .working(let op): "\(op.title) (\(process.title.lowercased()))"
        case .done(_, _, let op): "\(op.title): done"
        }
    }

    /// Shown again when the tab comes to the front: the buttons are the sheet's.
    func activate() { render() }

    func closed() {
        loadTask?.cancel()
        Form.clear(passphraseField)
    }

    // MARK: Content

    private func render() {
        sheet.canClose = true
        sheet.setBusy(nil)
        processPicker.isVisible = mode == .overview
        heading.isVisible = mode != .overview
        UI.setText(heading, title)
        feeValue = nil
        switch mode {
        case .overview:
            body.setChildren(overview())
        case .confirm(let op):
            body.setChildren([confirmationForm(op)])
        case .working(let op):
            sheet.canClose = false
            sheet.setBusy(signsOnLedger ? "\(op.title): confirm on your Ledger, then we wait for the next block…" : "\(op.title)… waiting for the next block")
            body.setChildren([])
        case .done(let hash, let level, _):
            body.setChildren([
                UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                     UI.label("Included in block \(level.formatted())", classes: ["success-icon"])]),
                OperationLink.make(hash, network: model.network),
            ])
        }
        updateButtons()
    }

    private func section(_ title: String?, _ rows: [Widget]) -> Widget {
        var children: [Widget] = []
        if let title { children.append(UI.label(title, classes: ["heading"])) }
        let group = Form.group([])
        for row in rows { Form.append(row, to: group) }
        children.append(group)
        return UI.vbox(spacing: 6, children)
    }

    private func overview() -> [Widget] {
        if let loadError {
            return [UI.hbox(spacing: 8, [UI.image(icon: "dialog-warning-symbolic").align(v: GTK_ALIGN_START), UI.label(loadError, wrap: true).expand(h: true)]).classes("warning-text")]
        }
        guard let state else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            return [UI.hbox(spacing: 8, [spinner, UI.label("Reading the governance contract…", classes: ["dim-label"])])]
        }
        var sections = [periodSection(state)]
        if !state.canVote {
            sections.append(section(nil, [Form.note("This account has no voting power on Etherlink: it is neither a baker in this period's listings nor a voting key that a baker has delegated to and that has claimed its rights.",
                                                    icon: "help-about-symbolic").row]))
        } else if state.periodKind == .proposal {
            sections.append(proposalSection(state))
        } else {
            sections.append(promotionSection(state))
        }
        // `.frame(height: 420)`: a long list of proposals scrolls inside the sheet.
        let column = UI.vbox(spacing: 16, sections)
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, column.pointer)
        gtk_scrolled_window_set_propagate_natural_height(scroller.opaque, 1)
        gtk_scrolled_window_set_max_content_height(scroller.opaque, 420)
        return [scroller]
    }

    private func monospaced(_ text: String, xalign: Float = 1) -> Widget {
        let label = UI.label(text, classes: ["address"], xalign: xalign)
        gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_selectable(label.opaque, 1)
        gtk_label_set_max_width_chars(label.opaque, 36)
        return label
    }

    private func periodSection(_ state: EtherlinkGovernance.State) -> Widget {
        var power = [UI.label("\(AssetBalance.format(state.votingPower / 1_000_000, symbol: "tz")) · \(percent(state.share(of: state.votingPower)))", xalign: 1)]
        if !state.votesFor.isEmpty {
            power.append(UI.label(state.votesFor.count == 1 ? "voting key of \(model.displayName(for: state.votesFor[0], indexerAlias: nil).name)" : "voting key of \(state.votesFor.count) bakers",
                                  classes: ["dim-label", "caption"], xalign: 1))
        }
        var contract = [monospaced(state.contract.value)]
        if let url = model.network.explorerURL(contract: state.contract.value) {
            contract.append(Widget(gtk_link_button_new_with_label(url.absoluteString, "Explorer")!))
        }
        let site = Widget(gtk_link_button_new_with_label(EtherlinkGovernance.siteURL.absoluteString, "Proposals are described at governance.etherlink.com")!)
        site.align(h: GTK_ALIGN_START)
        return section("Current period", [
            Form.labeled("Period", value: "\(state.periodKind.title) (#\(state.periodIndex))").row,
            Form.labeled("Remaining", value: "\(state.remainingBlocks.formatted()) blocks of \(state.config.periodLength.formatted())").row,
            Form.labeled("Your voting power", content: UI.vbox(spacing: 2, power)),
            Form.labeled("Contract", content: UI.hbox(spacing: 6, contract)),
            Form.row(site),
        ])
    }

    private func proposalSection(_ state: EtherlinkGovernance.State) -> Widget {
        var rows: [Widget] = []
        if !state.proposalsKnown {
            rows.append(Form.note("The proposals cannot be listed without a TzKT API for this network; paste a kernel hash to upvote it.", icon: "help-about-symbolic").row)
        } else if state.proposals.isEmpty {
            rows.append(Form.note("No kernels have been proposed yet in this period.").row)
        }
        let full = state.upvotesUsed >= state.config.upvotingLimit
        for proposal in state.proposals {
            let text = UI.vbox(spacing: 2, [
                monospaced(proposal.hash, xalign: 0),
                UI.label("\(percent(state.share(of: proposal.upvotes))) of voting power, needs \(percent(state.config.fraction(state.config.proposalQuorum))) · proposed by \(proposers(proposal))",
                         classes: ["dim-label", "caption"], wrap: true),
            ]).expand(h: true)
            let end: Widget
            if proposal.upvoted {
                end = UI.hbox(spacing: 4, [UI.image(icon: "object-select-symbolic"), UI.label("Upvoted")]).classes("success-icon")
            } else {
                end = UI.button("Upvote…") { [unowned self] in self.startConfirm(.upvote(hash: proposal.hash)) }
                end.isSensitive = !full
            }
            rows.append(Form.row(UI.hbox(spacing: 8, [text, end.align(v: GTK_ALIGN_CENTER)])))
        }
        rows.append(newHashField)
        let problem = Form.note("A kernel hash is 0x followed by 66 hexadecimal digits.", style: "warning-text").row
        hashProblem = problem
        rows.append(problem)
        rows.append(Form.note("You have used \(state.upvotesUsed) of \(state.config.upvotingLimit) upvotes this period; proposing counts as one. Upvoting cannot be undone.").row)
        let upvote = UI.button("Upvote…") { [unowned self] in if let hash = self.typedHash { self.startConfirm(.upvote(hash: hash)) } }
        let propose = UI.button("Propose…") { [unowned self] in if let hash = self.typedHash { self.startConfirm(.newProposal(hash: hash)) } }
        typedButtons = [upvote, propose]
        rows.append(Form.row(UI.hbox(spacing: 8, typedButtons)))
        updateTyped()
        return section("Proposals", rows)
    }

    private var typedHash: String? { EtherlinkGovernance.kernelHash(from: Form.text(newHashField)) }
    /// A listed kernel has its own Upvote button and cannot be proposed again.
    private var typedHashIsListed: Bool { typedHash.map { hash in state?.proposals.contains { $0.hash == hash } ?? false } ?? false }

    private func updateTyped() {
        let typed = Form.text(newHashField).trimmingCharacters(in: .whitespaces)
        hashProblem?.isVisible = !typed.isEmpty && typedHash == nil
        let full = state.map { $0.upvotesUsed >= $0.config.upvotingLimit } ?? true
        for button in typedButtons { button.isSensitive = typedHash != nil && !typedHashIsListed && !full }
    }

    private func proposers(_ proposal: EtherlinkGovernance.Proposal) -> String {
        guard let first = proposal.proposers.first else { return "unknown" }
        let name = model.displayName(for: first, indexerAlias: nil).name
        return proposal.proposers.count > 1 ? "\(name) and \(proposal.proposers.count - 1) more" : name
    }

    private func promotionSection(_ state: EtherlinkGovernance.State) -> Widget {
        var rows: [Widget] = []
        if let candidate = state.candidate { rows.append(Form.labeled("Kernel", content: monospaced(candidate))) }
        rows.append(Form.labeled("So far", value: "Yea \(percent(share(state.tallies.yea, of: state.tallies.total))) · Nay \(percent(share(state.tallies.nay, of: state.tallies.total))) · Pass \(percent(share(state.tallies.pass, of: state.tallies.total)))").row)
        rows.append(Form.labeled("Turnout", value: "\(percent(state.share(of: state.tallies.total))) of \(percent(state.config.fraction(state.config.promotionQuorum))) quorum").row)
        rows.append(Form.labeled("Supermajority", value: "\(percent(share(state.tallies.yea, of: state.tallies.yea + state.tallies.nay))) Yea of \(percent(state.config.fraction(state.config.promotionSupermajority))) needed").row)
        if let mine = state.myVote {
            rows.append(Form.note("You voted \(mine.title) in this period. A vote cannot be changed.", icon: "object-select-symbolic", style: "success-icon").row)
        } else if state.candidate != nil {
            rows.append(Form.row(UI.hbox(spacing: 10, EtherlinkGovernance.Vote.allCases.map { vote in
                UI.button(vote.title) { [unowned self] in self.startConfirm(.vote(vote)) }
            })))
            rows.append(Form.note("Yea supports the kernel, Nay opposes it, Pass counts towards the quorum without taking a side.").row)
        }
        return section("Promotion vote", rows)
    }

    private func share(_ part: Decimal, of whole: Decimal) -> Double {
        guard whole > 0 else { return 0 }
        return (part / whole as NSDecimalNumber).doubleValue
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...2)))
    }

    // MARK: Confirm

    private func confirmationForm(_ op: EtherlinkGovernance.Operation) -> Widget {
        var rows = [Form.labeled("Operation", value: op.title).row]
        if let hash = op.kernelHash { rows.append(Form.labeled("Kernel", content: monospaced(hash))) }
        if case .vote(let vote) = op, let candidate = state?.candidate {
            rows.append(Form.labeled("Kernel", content: monospaced(candidate)))
            rows.append(Form.labeled("Vote", value: vote.title).row)
        }
        if let contract = model.etherlinkGovernanceContract(for: process) {
            rows.append(Form.labeled("Contract", content: monospaced(contract.value)))
        }
        let fee = UI.hbox(spacing: 6)
        feeValue = fee
        updateFee()
        rows.append(Form.labeled("Fee", content: fee))
        if needsPassphrase { rows.append(passphraseField) }
        if signsOnLedger { rows.append(Form.note("Your Ledger will show this operation for approval.").row) }
        let group = Form.group([])
        for row in rows { Form.append(row, to: group) }
        if needsPassphrase { sheet.focus(passphraseField) }
        return group
    }

    private func updateFee() {
        guard let feeValue else { return }
        if let estimate {
            feeValue.setChildren([UI.label(AssetBalance.format(estimate.estimate.fee, symbol: "tz"))])
        } else if let estimateError {
            let label = UI.label(estimateError, classes: ["warning-text"], wrap: true, xalign: 1)
            gtk_label_set_max_width_chars(label.opaque, 40)
            feeValue.setChildren([label])
        } else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            feeValue.setChildren([spinner, UI.label("Estimating…", classes: ["dim-label"])])
        }
    }

    // MARK: Buttons

    func updateButtons() {
        switch mode {
        case .overview:
            sheet.setButtons([sheet.button("Done", isDefault: true) { [unowned sheet] in sheet.dismiss() }])
        case .confirm(let op):
            let back = sheet.button("Back") { [unowned self] in self.sheet.setError(nil); self.mode = .overview }
            let confirm = sheet.button("Confirm", role: .prominent, isDefault: true) { [unowned self] in
                guard self.estimate != nil, !(self.needsPassphrase && Form.text(self.passphraseField).isEmpty) else { return }
                Task { await self.perform(op) }
            }
            confirm.isSensitive = estimate != nil && !(needsPassphrase && Form.text(passphraseField).isEmpty)
            sheet.setButtons([back, confirm])
        case .working:
            sheet.setButtons([])
        case .done:
            sheet.setButtons([sheet.button("Done", role: .prominent, isDefault: true) { [unowned sheet] in sheet.dismiss() }])
        }
    }

    // MARK: Actions

    /// `.task(id: process)`.
    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        let process = process
        loadError = nil
        state = nil
        if mode == .overview { render() }
        do {
            let loaded = try await model.etherlinkGovernanceState(for: process)
            guard !Task.isCancelled, process == self.process else { return }
            state = loaded
        } catch {
            guard !Task.isCancelled, process == self.process else { return }
            loadError = "Could not read the governance contract: \(error.localizedDescription)"
        }
        if mode == .overview { render() }
    }

    private func startConfirm(_ op: EtherlinkGovernance.Operation) {
        sheet.setError(nil)
        estimate = nil
        estimateError = nil
        confirmation += 1
        let ticket = confirmation
        mode = .confirm(op)
        // `.task(id: op) { await estimate(op) }`.
        Task {
            do {
                let result = try await model.estimateEtherlinkGovernance(op, process: process)
                guard ticket == confirmation else { return }
                estimate = result
            } catch {
                guard ticket == confirmation else { return }
                estimateError = error.localizedDescription
            }
            updateFee()
            updateButtons()
        }
    }

    private func perform(_ op: EtherlinkGovernance.Operation) async {
        sheet.setError(nil)
        confirmation += 1
        mode = .working(op)
        do {
            let result = try await model.performEtherlinkGovernance(op, process: process, approved: estimate, passphrase: needsPassphrase ? Form.text(passphraseField) : nil)
            Form.clear(passphraseField)
            mode = .done(hash: result.hash, level: result.level, op)
            Form.clear(newHashField)
            await load()
        } catch {
            sheet.setError(error.localizedDescription)
            mode = .confirm(op)
            // The estimate stands: going back to confirm keeps it, as upstream's does.
            updateFee()
            updateButtons()
        }
    }
}
