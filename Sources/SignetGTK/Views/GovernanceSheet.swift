import CAdwaita
import Foundation

/// Governance for an account we can sign for: on-chain protocol voting for a baker (upvote
/// proposals in a proposal period, cast a ballot in the exploration and promotion votes). The
/// GTK counterpart of upstream's `Views/GovernanceSheet.swift` and its `TezosGovernanceView`;
/// the Etherlink tab (`EtherlinkGovernanceView`) is not ported.
@MainActor
final class GovernanceSheet: Sheet {
    enum Mode: Equatable { case overview, confirm(GovernanceOperation), working(GovernanceOperation), done(hash: String, level: Int, GovernanceOperation) }

    private var mode: Mode = .overview { didSet { render() } }
    private var info: GovernanceInfo?
    private var loadError: String?
    private var selected: Set<String> = []
    private let wallet: Wallet?
    private let body = UI.vbox(spacing: 12)
    private var passphraseField: Widget!
    private var newProposalField: Widget!
    private var upvoteButton: Widget?
    private var proposalProblem: Widget?

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 560)
        content.setChildren([Sheet.accountTitle("Governance", wallet: wallet).root, body])
        passphraseField = Form.password("Password for “\(wallet?.alias ?? "")”", onChange: { [unowned self] in self.updateButtons() })
        newProposalField = Form.entry("Or a new proposal hash (P…)", monospaced: true, onChange: { [unowned self] in self.updateUpvote() })
        render()
        Task { await load() }
    }

    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }

    private var title: String {
        switch mode {
        case .overview: "Tezos"
        case .confirm(let op), .working(let op): op.title
        case .done(_, _, let op): "\(op.title): done"
        }
    }

    private func render() {
        canClose = true
        setBusy(nil)
        var children: [Widget] = []
        if mode != .overview { children.append(UI.label(title, classes: ["heading"])) }
        switch mode {
        case .overview: children += overview()
        case .confirm(let op): children.append(confirmation(op))
        case .working(let op):
            canClose = false
            setBusy(signsOnLedger ? "\(op.title): confirm on your Ledger, then we wait for the next block…" : "\(op.title)… waiting for the next block")
        case .done(let hash, let level, _):
            children.append(UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                                 UI.label("Included in block \(level.formatted())", classes: ["success-icon"])]))
            children.append(OperationLink.make(hash, network: model.network))
        }
        body.setChildren(children)
        updateButtons()
    }

    // MARK: Overview

    private func section(_ title: String?, _ rows: [Widget]) -> Widget {
        var children: [Widget] = []
        if let title { children.append(UI.label(title, classes: ["heading"])) }
        children.append(Form.group(rows))
        return UI.vbox(spacing: 6, children)
    }

    private func note(_ text: String, icon: String, style: String = "dim-label") -> Widget {
        UI.hbox(spacing: 8, [UI.image(icon: icon).align(v: GTK_ALIGN_START), UI.label(text, wrap: true).expand(h: true)]).classes(style)
    }

    private func overview() -> [Widget] {
        if model.delegateInfo?.isBaker != true {
            return [note("Tezos protocol voting is for bakers. This account is not a baker, so it can only vote on Etherlink.", icon: "help-about-symbolic")]
        }
        if let loadError { return [note(loadError, icon: "dialog-warning-symbolic", style: "warning-text")] }
        guard let info else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            return [UI.hbox(spacing: 8, [spinner, UI.label("Reading the voting period…", classes: ["dim-label"])])]
        }
        var sections = [periodSection(info)]
        if let kind = info.kind {
            if !info.canVote {
                sections.append(section(nil, [Form.note("This baker is not in the voting listings for this period, so it cannot vote until the next period starts. Bakers need baking rights (enough stake) when the period opens.", icon: "help-about-symbolic").row]))
            } else if kind.acceptsUpvotes {
                sections.append(proposalSection(info))
            } else if kind.acceptsBallots {
                sections.append(ballotSection(info))
            } else {
                sections.append(section(nil, [Form.note(kind == .cooldown
                    ? "Nothing to vote on: the cooldown period gives everyone time between the exploration and promotion votes."
                    : "Nothing to vote on: the adoption period waits for the new protocol to activate.").row]))
            }
        }
        return sections
    }

    private func periodSection(_ info: GovernanceInfo) -> Widget {
        var rows = [Form.labeled("Period", value: info.kind.map { "\($0.title)\(info.index.map { " (#\($0))" } ?? "")" } ?? "No governance period").row]
        if let remaining = info.remaining { rows.append(Form.labeled("Remaining", value: "\(remaining.formatted()) blocks").row) }
        if let power = info.votingPower {
            rows.append(Form.labeled("Your voting power", value: "\(AssetBalance.format(power / 1_000_000, symbol: "tz")) · \(percent(info.share(of: power)))").row)
        }
        return section("Current period", rows)
    }

    private func proposalSection(_ info: GovernanceInfo) -> Widget {
        var rows: [Widget] = []
        if info.proposals.isEmpty { rows.append(Form.note("No proposals have been submitted yet in this period.").row) }
        for proposal in info.proposals {
            let hash = UI.label(proposal.hash, classes: ["address"])
            gtk_label_set_ellipsize(hash.opaque, PANGO_ELLIPSIZE_MIDDLE)
            let check = Widget(gtk_check_button_new()!)
            gtk_check_button_set_active(check.as(), selected.contains(proposal.hash) ? 1 : 0)
            gtk_check_button_set_child(check.as(), UI.vbox(spacing: 2, [hash, UI.label("\(percent(info.share(of: proposal.votingPower))) of voting power", classes: ["dim-label", "caption"])]).pointer)
            Signals.connect(check, "toggled") { [unowned self] in
                if gtk_check_button_get_active(check.as()) != 0 { self.selected.insert(proposal.hash) } else { self.selected.remove(proposal.hash) }
                self.updateUpvote()
            }
            rows.append(Form.row(check))
        }
        rows.append(newProposalField)
        let problem = Form.note("That is not a protocol hash (51 characters starting with P).", style: "warning-text").row
        proposalProblem = problem
        rows.append(problem)
        rows.append(Form.note("A baker may upvote up to \(GovernanceInfo.maximumUpvotesPerPeriod) proposals per period; you have used \(info.proposalCount). Upvoting cannot be undone.").row)
        let upvote = UI.button("Upvote…") { [unowned self] in self.startConfirm(.upvote(self.upvoteHashes)) }.align(h: GTK_ALIGN_START)
        upvoteButton = upvote
        rows.append(Form.row(upvote))
        updateUpvote()
        return section("Proposals", rows)
    }

    private var upvoteHashes: [String] {
        var hashes = Array(selected).sorted()
        let typed = Form.text(newProposalField).trimmingCharacters(in: .whitespaces)
        if GovernanceOperation.isProposalHash(typed), !hashes.contains(typed) { hashes.append(typed) }
        return hashes
    }

    private func updateUpvote() {
        let typed = Form.text(newProposalField).trimmingCharacters(in: .whitespaces)
        proposalProblem?.isVisible = !typed.isEmpty && !GovernanceOperation.isProposalHash(typed)
        guard let info else { return }
        upvoteButton?.isSensitive = !upvoteHashes.isEmpty && info.proposalCount + upvoteHashes.count <= GovernanceInfo.maximumUpvotesPerPeriod
    }

    private func ballotSection(_ info: GovernanceInfo) -> Widget {
        var rows: [Widget] = []
        if let proposal = info.currentProposal { rows.append(proposalRow(proposal)) }
        rows.append(Form.labeled("So far", value: "Yay \(percent(share(info.ballots.yay, of: info.ballots.total))) · Nay \(percent(share(info.ballots.nay, of: info.ballots.total))) · Pass \(percent(share(info.ballots.pass, of: info.ballots.total)))").row)
        if let quorum = info.quorumPerTenThousand {
            rows.append(Form.labeled("Turnout", value: "\(percent(info.share(of: info.ballots.total))) of \(percent(Double(quorum) / 10_000)) quorum").row)
        }
        if let mine = info.myBallot {
            rows.append(Form.note("You voted \(mine.title) in this period. A ballot cannot be changed.", icon: "object-select-symbolic", style: "success-icon").row)
        } else if let proposal = info.currentProposal {
            rows.append(Form.row(UI.hbox(spacing: 10, BallotVote.allCases.map { vote in
                UI.button(vote.title) { [unowned self] in self.startConfirm(.ballot(proposal: proposal, vote: vote)) }
            })))
            rows.append(Form.note("Yay supports the proposal, Nay opposes it, Pass counts towards the quorum without taking a side.").row)
        }
        return section(info.kind == .exploration ? "Exploration vote" : "Promotion vote", rows)
    }

    private func proposalRow(_ proposal: String) -> Widget {
        let label = UI.label(proposal, classes: ["address"], xalign: 1)
        gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_selectable(label.opaque, 1)
        gtk_label_set_max_width_chars(label.opaque, 36)
        return Form.labeled("Proposal", content: label)
    }

    private func share(_ part: Decimal, of whole: Decimal) -> Double {
        guard whole > 0 else { return 0 }
        return (part / whole as NSDecimalNumber).doubleValue
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...2)))
    }

    // MARK: Confirm

    private func confirmation(_ op: GovernanceOperation) -> Widget {
        var rows = [Form.labeled("Operation", value: op.title).row]
        switch op {
        case .upvote(let hashes):
            rows += hashes.map(proposalRow)
        case .ballot(let proposal, let vote):
            rows.append(proposalRow(proposal))
            rows.append(Form.labeled("Ballot", value: vote.title).row)
        }
        rows.append(Form.labeled("Fee", value: "None (voting operations are free)").row)
        if needsPassphrase { rows.append(passphraseField); focus(passphraseField) }
        if signsOnLedger { rows.append(Form.note("Your Ledger will show this operation for approval.").row) }
        return Form.group(rows)
    }

    // MARK: Buttons

    private func updateButtons() {
        switch mode {
        case .overview:
            setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        case .confirm(let op):
            let confirm = button("Confirm", role: .prominent, isDefault: true) { [unowned self] in Task { await self.perform(op) } }
            confirm.isSensitive = !(needsPassphrase && Form.text(passphraseField).isEmpty)
            setButtons([button("Back") { [unowned self] in self.setError(nil); self.mode = .overview }, confirm])
        case .working:
            setButtons([])
        case .done:
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    private func load() async {
        guard model.delegateInfo?.isBaker == true else { return }
        loadError = nil
        do { info = try await model.governanceInfo() } catch { loadError = "Could not read the voting period: \(error.localizedDescription)" }
        if mode == .overview { render() }
    }

    private func startConfirm(_ op: GovernanceOperation) {
        setError(nil)
        mode = .confirm(op)
    }

    private func perform(_ op: GovernanceOperation) async {
        setError(nil)
        mode = .working(op)
        do {
            let result = try await model.performGovernance(op, passphrase: needsPassphrase ? Form.text(passphraseField) : nil)
            Form.clear(passphraseField)
            selected = []
            Form.clear(newProposalField)
            mode = .done(hash: result.hash, level: result.level, op)
            await load()
        } catch {
            setError(error.localizedDescription)
            mode = .confirm(op)
        }
    }

    override func closed() { Form.clear(passphraseField) }
}
