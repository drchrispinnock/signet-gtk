import CAdwaita
import Foundation

/// Move assets (under Bridge in the burger menu): everything one account holds goes to another
/// account in the list or address book: tez, tokens and NFTs, on Tezos and, with Layer 2 on, on
/// Etherlink, and on Mainnet the Tezos Domains names it owns. Choose the two accounts, accept
/// that the move may be one way (and, when Signet holds no key for the destination, that it is
/// out of reach from here), review what the plan found, then each layer goes out as operation
/// groups one after another. Staked or unstaking tez, or a baker, stop it at the review
/// (`planMoveAssets`). The GTK counterpart of upstream's `Views/MoveAssetsSheet.swift`.
@MainActor
final class MoveAssetsSheet: Sheet {
    enum Step: Hashable { case choose, warn, review, working, done }

    private var step: Step = .choose
    private var sourceID: Wallet.ID?
    private var destinationID: Wallet.ID?
    private var understoodOneWay = false
    private var understoodNoKey = false
    private var plan: WalletViewModel.MoveAssetsPlan?
    private var planError: String?
    private var isPlanning = false
    private var completed: [WalletViewModel.MoveAssetsStep] = []
    private var planTask: Task<Void, Never>?

    private let body = UI.vbox(spacing: 14)
    private let password: PasswordField
    private var sourcePicker: Widget!
    private var destinationPicker: Widget!
    /// The destinations as the To picker lists them, after "Choose an account".
    private var listedDestinations: [Wallet] = []

    init(model: WalletViewModel) {
        let selected = model.selectedWallet
        sourceID = model.moveSources.contains { $0.id == selected?.id } ? selected?.id : model.moveSources.first?.id
        password = PasswordField(model: model, wallet: nil)
        super.init(model: model, width: 560)
        password.onChange = { [unowned self] in self.updateButtons() }
        content.setChildren([Sheet.title("Move assets"), body])
        render()
    }

    private var source: Wallet? { plan?.source ?? model.moveSources.first { $0.id == sourceID } }
    private var destination: Wallet? { plan?.destination ?? model.moveDestinations(from: source).first { $0.id == destinationID } }
    private var destinationHoldsKey: Bool { destination.map(WalletViewModel.holdsKey(of:)) ?? true }
    private var needsPassphrase: Bool { model.needsPassphrase(for: source) }
    private var signsOnLedger: Bool { source?.keyKind == .ledger }

    // MARK: Steps

    private func render() {
        setBusy(nil)
        canClose = step != .working
        switch step {
        case .choose: body.setChildren(chooser())
        case .warn: body.setChildren([pair()] + warnings())
        case .review: body.setChildren([pair()] + review())
        case .working, .done: body.setChildren([pair()] + progress())
        }
        updateButtons()
    }

    private func title(_ wallet: Wallet) -> String { "\(wallet.alias)  \(wallet.address.shortened())" }

    private func chooser() -> [Widget] {
        let sources = model.moveSources
        sourcePicker = Form.picker("From", options: sources.map(title), selected: sources.firstIndex { $0.id == sourceID } ?? 0) { [unowned self] in
            let index = Form.selected(self.sourcePicker)
            guard sources.indices.contains(index), sources[index].id != self.sourceID else { return }
            self.sourceID = sources[index].id
            if self.destinationID == self.sourceID { self.destinationID = nil }
            self.render()
        }
        // My accounts first, then the address book (upstream's two sections).
        let destinations = model.moveDestinations(from: source)
        listedDestinations = destinations.filter(WalletViewModel.holdsKey(of:)) + destinations.filter { !WalletViewModel.holdsKey(of: $0) }
        let options = ["Choose an account"] + listedDestinations.map { title($0) + (WalletViewModel.holdsKey(of: $0) ? "" : "  (address book)") }
        let chosen = listedDestinations.firstIndex { $0.id == destinationID }.map { $0 + 1 } ?? 0
        destinationPicker = Form.picker("To", options: options, selected: chosen) { [unowned self] in
            let index = Form.selected(self.destinationPicker) - 1
            self.destinationID = self.listedDestinations.indices.contains(index) ? self.listedDestinations[index].id : nil
            self.updateButtons()
        }
        let network = model.network
        let what = "Everything in the first account moves to the second: its tez, tokens and NFTs on \(network.name)\(network.hasL2 ? " and on \(network.l2Name)" : "")\(network.tezosDomainsURL != nil ? ", and the Tezos Domains names it owns, pointed at the new account" : "")."
        return [Form.group([sourcePicker, destinationPicker, Form.note(what).row])]
    }

    private func warnings() -> [Widget] {
        var groups: [Widget] = []
        var oneWay: Widget!
        oneWay = Form.toggle("I understand that the move cannot be undone from here", isOn: understoodOneWay) { [unowned self] in
            self.understoodOneWay = Form.isOn(oneWay)
            self.updateButtons()
        }
        groups.append(Form.group([
            Form.note("Moving assets may be one way.", icon: "dialog-warning-symbolic", style: "warning-text").row,
            Form.note("Signet cannot undo the move. Getting anything back means sending it back from “\(destination?.alias ?? "")”, which only whoever holds that account's key can do, and costs fees again.").row,
            oneWay,
        ]))
        if !destinationHoldsKey, let destination {
            var noKey: Widget!
            noKey = Form.toggle("I hold the key to “\(destination.alias)” elsewhere, or I mean to give these assets away", isOn: understoodNoKey) { [unowned self] in
                self.understoodNoKey = Form.isOn(noKey)
                self.updateButtons()
            }
            groups.append(Form.group([
                Form.note("Signet does not hold the key for “\(destination.alias)”.", icon: "dialog-error-symbolic", style: "error-text").row,
                Form.note("It is \(destination.keyKind == .none ? "an address book entry" : "an account Signet cannot sign for"). Unless you hold its key somewhere else, everything moved there is out of your reach for good.").row,
                noKey,
            ]))
        }
        return groups
    }

    private func review() -> [Widget] {
        if isPlanning {
            return [UI.hbox(spacing: 8, [spinner(), UI.label("Reading balances and NFTs, and estimating fees…", classes: ["dim-label"])])]
        }
        if let planError {
            return [UI.hbox(spacing: 8, [UI.image(icon: "dialog-error-symbolic").classes("error-text").align(v: GTK_ALIGN_START),
                                         UI.label(planError, classes: ["error-text"], wrap: true).expand(h: true)])]
        }
        guard let plan else { return [] }
        var sections: [Widget] = []
        for layer in plan.layers {
            var rows = [
                Form.labeled("Tez", value: AssetBalance.format(layer.tez, symbol: "tz")).row,
                Form.labeled("Tokens", value: layer.tokens.isEmpty ? "None" : layer.tokens.count <= 3 ? layer.tokens.map(\.formattedAmount).joined(separator: ", ") : "\(layer.tokens.count) tokens").row,
                Form.labeled("NFTs", value: layer.nfts.isEmpty ? "None" : "\(layer.nfts.count) (\(layer.editions) edition\(layer.editions == 1 ? "" : "s"))").row,
            ]
            if !layer.domains.isEmpty || !layer.domainsLeftBehind.isEmpty {
                rows.append(Form.labeled("Domains", value: layer.domains.isEmpty ? "None" : layer.domains.count <= 3 ? layer.domains.map(\.name).joined(separator: ", ") : "\(layer.domains.count) names").row
                    .tooltip("Each name moves to the new account and is pointed at it."))
            }
            rows.append(Form.labeled("Fees and storage", value: AssetBalance.format(layer.cost, symbol: "tz")).row)
            if layer.batches.count > 1 {
                rows.append(Form.note("\(layer.batches.count) operations, one after another (at most \(TokenTransferRequest.maxTokens) tokens and NFTs each).").row)
            }
            if !layer.domainsLeftBehind.isEmpty {
                let count = layer.domainsLeftBehind.count
                rows.append(Form.note("\(count) name\(count == 1 ? "" : "s") stay\(count == 1 ? "s" : ""): expired, or owned by someone else and only pointing here.").row)
            }
            if !layer.tokensLeftBehind.isEmpty {
                let count = layer.tokensLeftBehind.count
                rows.append(Form.note("\(count) token\(count == 1 ? "'s" : "s'") exact balance is unknown, so \(count == 1 ? "it stays" : "they stay").", style: "warning-text").row)
            }
            if !layer.leftBehind.isEmpty {
                let count = layer.leftBehind.count
                rows.append(Form.note("\(count) NFT\(count == 1 ? " is" : "s are") marked as not transferable and stay\(count == 1 ? "s" : "").", style: "warning-text").row)
            }
            sections.append(UI.vbox(spacing: 6, [UI.label(layer.name, classes: ["heading"]), Form.group(rows)]))
        }
        if !plan.notes.isEmpty {
            sections.append(Form.group(plan.notes.map { Form.note($0, style: "warning-text").row }))
        }
        if source?.keyKind == .encrypted {
            password.wallet = source
            sections.append(Form.group(password.rows))
        }
        sections.append(UI.label("“\(plan.source.alias)” is left empty, apart from a little tez the fee estimate may have kept back.", classes: ["dim-label", "caption"], wrap: true))
        if needsPassphrase { focus(password.entry) }
        return sections
    }

    private func progress() -> [Widget] {
        var rows: [Widget] = completed.map { done in
            var line = [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                        UI.label("\(plan?.layers.first { $0.layer == done.layer }?.name ?? "") · block \(done.level.formatted())")]
            let hash = UI.label(done.hash, classes: ["address", "dim-label"])
            gtk_label_set_ellipsize(hash.opaque, PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_selectable(hash.opaque, 1)
            line.append(hash.expand(h: true))
            if let url = done.explorerURL { line.append(UI.button("Explorer", classes: ["flat"]) { [unowned self] in UI.open(url, from: self.body) }) }
            return UI.hbox(spacing: 8, line)
        }
        if step == .working {
            setBusy(signsOnLedger ? "Confirm the move on your Ledger…" : "Moving… operation \(completed.count + 1) of \(plan?.batchCount ?? 1)")
        } else if let plan, !hasError {
            rows.append(UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                             UI.label("Moved to “\(plan.destination.alias)”.", classes: ["success-icon", "heading"])]))
        }
        return rows
    }

    private var hasError = false

    private func pair() -> Widget {
        UI.hbox(spacing: 10, [accountLabel(source), UI.image(icon: "go-next-symbolic").classes("dim-label"), accountLabel(destination), UI.hspacer()])
    }

    private func accountLabel(_ wallet: Wallet?) -> Widget {
        guard let wallet else { return UI.hbox(spacing: 0) }
        return UI.hbox(spacing: 6, [
            AccountAvatarView(address: wallet.address, size: 28).root,
            UI.vbox(spacing: 0, [UI.label(wallet.alias, classes: ["heading"]), UI.label(wallet.address.shortened(), classes: ["address", "dim-label", "caption"])])
                .align(v: GTK_ALIGN_CENTER),
        ])
    }

    private func spinner() -> Widget {
        let spinner = Widget(gtk_spinner_new()!)
        gtk_spinner_start(spinner.opaque)
        return spinner
    }

    private func updateButtons() {
        var buttons: [Widget] = []
        if step == .warn || (step == .review && !isPlanning) {
            buttons.append(button("Back") { [unowned self] in self.back() })
        }
        switch step {
        case .choose:
            let next = button("Continue", role: .prominent, isDefault: true) { [unowned self] in
                guard self.source != nil, self.destination != nil else { return }
                self.setError(nil)
                self.step = .warn
                self.render()
            }
            next.isSensitive = source != nil && destination != nil
            buttons += [cancelButton(), next]
        case .warn:
            let next = button("Continue", role: .prominent, isDefault: true) { [unowned self] in
                guard self.understoodOneWay, self.destinationHoldsKey || self.understoodNoKey else { return }
                self.step = .review
                self.startPlan()
            }
            next.isSensitive = understoodOneWay && (destinationHoldsKey || understoodNoKey)
            buttons += [cancelButton(), next]
        case .review:
            let canMove = plan != nil && !isPlanning && !(needsPassphrase && password.text.isEmpty)
            let move = button("Move", role: .destructive, isDefault: true) { [unowned self] in
                guard self.plan != nil, !self.isPlanning, !(self.needsPassphrase && self.password.text.isEmpty) else { return }
                Task { await self.move() }
            }
            move.isSensitive = canMove
            buttons += [cancelButton(), move]
        case .working:
            let cancel = cancelButton()
            cancel.isSensitive = false
            buttons.append(cancel)
        case .done:
            buttons.append(button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() })
        }
        setButtons(buttons)
    }

    // MARK: Actions

    private func back() {
        setError(nil)
        if step == .review {
            planTask?.cancel()
            plan = nil
            planError = nil
            step = .warn
        } else {
            step = .choose
        }
        render()
    }

    /// `.task(id: step) { if step == .review, plan == nil { await makePlan() } }`.
    private func startPlan() {
        guard plan == nil else { render(); return }
        planTask?.cancel()
        planTask = Task { await makePlan() }
    }

    private func makePlan() async {
        guard let source, let destination else { return }
        isPlanning = true
        planError = nil
        render()
        do {
            let made = try await model.planMoveAssets(from: source, to: destination)
            if !Task.isCancelled { plan = made }
        } catch {
            if !Task.isCancelled { planError = error.localizedDescription }
        }
        isPlanning = false
        if !Task.isCancelled, step == .review { render() }
    }

    private func move() async {
        guard let plan else { return }
        setError(nil)
        hasError = false
        completed = []
        step = .working
        render()
        do {
            try await model.moveAssets(plan, passphrase: needsPassphrase ? password.text : nil) { [unowned self] in
                self.completed.append($0)
                self.render()
            }
            password.clear()
            step = .done
        } catch {
            var message = error.localizedDescription
            hasError = true
            if completed.isEmpty {
                // Nothing went out (a wrong password, a Ledger that was not ready…): plan again.
                self.plan = nil
                step = .review
                setError(message)
                await makePlan()
                return
            }
            message += " The operations listed above went through; the rest did not. Start Move assets again for what is left."
            setError(message)
            step = .done
        }
        render()
    }

    override func closed() {
        planTask?.cancel()
        password.clear()
    }
}
