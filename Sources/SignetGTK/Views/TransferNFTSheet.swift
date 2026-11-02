import CAdwaita
import Foundation

/// Transfers or burns the NFTs chosen in the grid (0.9.13): the tokens with how many editions
/// of each, the recipient (an address, a `.tez` name or one of our accounts; the burn address
/// for a burn), the fee and storage burn from the estimate, then the result. One FA2
/// `transfer` call per contract goes out in one operation group with the approved limits
/// (S14), bound to the account, network and directory the estimate was made in (S31). The GTK
/// counterpart of upstream's `Views/TransferNFTSheet.swift`.
@MainActor
final class TransferNFTSheet: Sheet {
    let operation: NFTOperation

    enum Step: Hashable { case compose, working, done(hash: String, level: Int) }

    /// Resolves the recipient as the Send sheet does (names, suggestions, Etherlink's tz1–tz3 rule).
    private let recipient: SendViewModel
    /// Editions of each token to move; a token held once has no choice.
    private var counts: [NFT.ID: Int]
    private var estimate: WalletViewModel.TokenTransferApproval?
    private var estimateError: String?
    private var step: Step = .compose
    private var submitted: WalletViewModel.TokenTransferApproval?
    private var estimateKey: EstimateKey?
    private var estimateTask: Task<Void, Never>?

    private let heading: Widget
    private let tokenList = UI.vbox(spacing: 0)
    private var spinButtons: [Widget] = []
    private let compose = UI.vbox(spacing: 12)
    private let recipientField: Widget
    private let recipientStatus = UI.hbox(spacing: 8)
    private let suggestions = UI.vbox(spacing: 0)
    private var shownSuggestions: [Wallet]?
    private var burnToggle: Widget!
    private let details = Form.group([])
    private let passphraseField: Widget
    private let passphraseGroup: Widget
    private let result = UI.vbox(spacing: 10)

    init(model: WalletViewModel, operation: NFTOperation) {
        self.operation = operation
        let sender = model.selectedWallet ?? Wallet(alias: "", address: Address(""), keyKind: .none)
        let chain = operation.layer == 2 ? (model.layer2Chain ?? model.chainService) : model.chainService
        recipient = SendViewModel(sender: sender, wallets: model.wallets, chain: chain, spendable: nil,
                                  implicitAccountsOnly: operation.layer == 2, signerProvider: { _, _ in nil })
        counts = Dictionary(uniqueKeysWithValues: operation.nfts.map { ($0.id, 1) })
        recipientField = Form.entry(operation.layer == 2 ? "To (tz1, tz2 or tz3 address, name.tez, or an account from your list)"
                                                         : "To (address, name.tez, or an account from your list)", monospaced: true)
        passphraseField = Form.password("Password for “\(model.selectedWallet?.alias ?? "")”")
        passphraseGroup = Form.group([passphraseField])
        let what = operation.nfts.count == 1 ? "NFT" : "\(operation.nfts.count) NFTs"
        let header = Sheet.accountTitle((operation.kind == .burn ? "Burn " : "Transfer ") + what + (operation.layer == 2 ? " on Etherlink" : ""),
                                        wallet: model.selectedWallet)
        heading = header.root
        super.init(model: model, width: 560)

        if isBurn {
            burnToggle = Form.toggle("I understand that \(editions == 1 ? "this token" : "these \(editions) tokens") will be gone for good", isOn: false) { [unowned self] in self.render() }
            let warning = UI.vbox(spacing: 6, [
                UI.hbox(spacing: 6, [UI.image(icon: "dialog-warning-symbolic"), UI.label("Burning is permanent.", classes: ["heading"])]).classes("warning-text"),
                UI.label("The tokens go to \(TokenTransferRequest.burnAddress.shortened()), an address nobody holds the key to, and can never be recovered or sold.",
                         classes: ["dim-label"], wrap: true),
            ])
            compose.setChildren([Form.group([Form.row(warning), burnToggle]), details, passphraseGroup])
        } else {
            Signals.connect(recipientField, "changed") { [unowned self] in self.recipient.recipientText = Form.text(self.recipientField) }
            let status = Form.row(UI.vbox(spacing: 6, [recipientStatus, suggestions]))
            compose.setChildren([Form.group([recipientField, status]), details, passphraseGroup])
        }
        Signals.connect(passphraseField, "changed") { [unowned self] in self.updateButtons() }
        content.setChildren([heading, tokens(), compose, result])

        trackers.append(Tracker { [unowned self] in
            // The recipient, the context and whether the account can sign follow their models.
            _ = (self.recipient.recipient, self.recipient.isResolving, self.recipient.suggestions, self.recipient.errorMessage,
                 self.model.bridgeContext, self.model.canTransferTokens(on: operation.layer))
            self.changed()
        })
        if !isBurn { focus(recipientField) }
    }

    private var isBurn: Bool { operation.kind == .burn }
    private var wallet: Wallet? { submitted?.context.wallet ?? model.selectedWallet }
    private var network: Network { model.tokenNetwork(on: operation.layer) }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var passphrase: String { Form.text(passphraseField) }
    private var understoodBurn: Bool { burnToggle.map { Form.isOn($0) } ?? false }

    /// The request as composed, once it is complete and sound.
    private var request: TokenTransferRequest? {
        if let submitted { return submitted.request }
        guard let to = isBurn ? TokenTransferRequest.burnAddress : recipient.recipient?.address else { return nil }
        let transfers = operation.nfts.map { TokenTransfer(nft: $0, amount: counts[$0.id] ?? 1) }
        guard operation.nfts.allSatisfy({ (counts[$0.id] ?? 1) >= 1 && Decimal(counts[$0.id] ?? 1) <= $0.balance }) else { return nil }
        let request = TokenTransferRequest(to: to, transfers: transfers)
        return request.isValid ? request : nil
    }
    private var editions: Int { operation.nfts.reduce(0) { $0 + (counts[$1.id] ?? 1) } }
    private var canConfirm: Bool {
        guard let request, let estimate, estimate.request == request, estimate.context == model.bridgeContext else { return false }
        return step == .compose && model.canTransferTokens(on: operation.layer) && !(needsPassphrase && passphrase.isEmpty) && (!isBurn || understoodBurn)
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

    /// The tokens going, with a count for those held in several editions.
    private func tokens() -> Widget {
        var rows: [Widget] = []
        for (index, nft) in operation.nfts.enumerated() {
            let thumbnail = RemoteImage.make(urls: nft.imageURLs, size: 44, round: false) {
                UI.vbox().size(width: 44, height: 44).classes("nft-placeholder")
            }
            thumbnail.classes("nft-thumb")
            gtk_widget_set_overflow(thumbnail.pointer, GTK_OVERFLOW_HIDDEN)
            let name = UI.label(nft.name)
            gtk_label_set_ellipsize(name.opaque, PANGO_ELLIPSIZE_END)
            var row = [thumbnail, UI.vbox(spacing: 2, [name, UI.label("\(Address(nft.contract).shortened()) #\(nft.tokenId)", classes: ["address", "dim-label", "caption"])])
                .expand(h: true).align(v: GTK_ALIGN_CENTER)]
            if nft.balance > 1 {
                let held = NSDecimalNumber(decimal: nft.balance).intValue
                let spin = Widget(gtk_spin_button_new_with_range(1, Double(max(1, held)), 1)!)
                gtk_spin_button_set_value(spin.opaque, 1)
                spin.align(v: GTK_ALIGN_CENTER).tooltip("How many of the \(held) editions held to \(isBurn ? "burn" : "transfer")")
                Signals.connect(spin, "value-changed") { [unowned self] in
                    self.counts[nft.id] = min(max(1, Int(gtk_spin_button_get_value_as_int(spin.opaque))), held)
                    self.changed()
                }
                spinButtons.append(spin)
                row.append(UI.hbox(spacing: 6, [spin, UI.label("of \(held)", classes: ["numeric"]).align(v: GTK_ALIGN_CENTER)]))
            }
            rows.append(UI.hbox(spacing: 10, row).margins(top: 6, bottom: 6, start: 8, end: 8))
            if index < operation.nfts.count - 1 { rows.append(UI.separator()) }
        }
        tokenList.setChildren(rows)
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, tokenList.pointer)
        gtk_scrolled_window_set_propagate_natural_height(scroller.opaque, 1)
        gtk_scrolled_window_set_max_content_height(scroller.opaque, Int32(min(operation.nfts.count, 4) * 60))
        return scroller.classes("card")
    }

    private func render() {
        setBusy(nil)
        canClose = step != .working
        switch step {
        case .compose:
            compose.isVisible = true
            renderRecipient()
            renderDetails()
        case .working:
            compose.isVisible = false
            setBusy(signsOnLedger ? "Confirm the \(isBurn ? "burn" : "transfer") on your Ledger…" : (isBurn ? "Burning…" : "Transferring…"))
        case .done(let hash, let level):
            compose.isVisible = false
            let what = editions == 1 ? "1 token" : "\(editions) tokens"
            result.setChildren([
                UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                     UI.label(isBurn ? "Burnt \(what)" : "Transferred \(what) to \(submitted.map { $0.request.to.shortened() } ?? "the recipient")",
                                              classes: ["success-icon", "heading"])]),
                UI.label("Included in block \(level.formatted()). The NFTs tab updates on the next refresh.", classes: ["dim-label"], wrap: true),
                OperationLink.make(hash, network: network),
            ])
        }
        for spin in spinButtons { spin.isSensitive = step == .compose }
        updateButtons()
    }

    private func renderRecipient() {
        guard !isBurn else { return }
        if let resolved = recipient.recipient {
            var children = [AccountAvatarView(address: resolved.address, size: 20).root, UI.label(resolved.displayName), VerificationTag.make(resolved)]
            if resolved.wallet == nil, let domain = resolved.domains.first, domain != resolved.displayName {
                children.append(UI.label(domain, classes: ["dim-label"]))
            }
            recipientStatus.setChildren(children)
        } else if recipient.isResolving {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            recipientStatus.setChildren([spinner, UI.label("Looking up name…", classes: ["dim-label"])])
        } else if let error = recipient.errorMessage {
            recipientStatus.setChildren([UI.label(error, classes: ["error-text"], wrap: true)])
        } else if !recipient.recipientText.isEmpty, recipient.suggestions.isEmpty {
            recipientStatus.setChildren([UI.image(icon: "dialog-warning-symbolic").classes("dim-label"), UI.label("Not a valid address or .tez name", classes: ["dim-label"])])
        } else {
            recipientStatus.setChildren([])
        }
        recipientStatus.isVisible = gtk_widget_get_first_child(recipientStatus.pointer) != nil

        let list = recipient.recipient == nil ? Array(recipient.suggestions.prefix(6)) : []
        suggestions.isVisible = !list.isEmpty
        gtk_widget_set_visible(gtk_widget_get_parent(gtk_widget_get_parent(suggestions.pointer)), recipientStatus.isVisible || !list.isEmpty ? 1 : 0)
        guard list != shownSuggestions else { return }
        shownSuggestions = list
        suggestions.setChildren(list.map { candidate in
            let row = UI.hbox(spacing: 8, [
                AccountAvatarView(address: candidate.address, size: 20).root, UI.label(candidate.alias),
                UI.label(candidate.address.shortened(), classes: ["address", "dim-label"]), UI.hspacer(),
                UI.label(candidate.keyKind == KeyKind.none ? "Address book" : "My account", classes: ["dim-label", "caption"]),
            ])
            return UI.button(content: row, classes: ["flat", "suggestion"]) { [recipient] in recipient.choose(candidate) }
        })
    }

    private func renderDetails() {
        var rows: [Widget] = []
        if let estimate = estimate?.estimate {
            rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
            if estimate.burn > 0 {
                rows.append(Form.labeled("Storage", value: AssetBalance.format(estimate.burn, symbol: "tz")).row
                    .tooltip("The contract's ledger grows for a recipient that has not held the token before; the chain charges for the space."))
            }
            rows.append(Form.labeled("Total", value: AssetBalance.format(estimate.total, symbol: "tz")).row)
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
        if !model.canTransferTokens(on: operation.layer) {
            rows.append(Form.note(operation.layer == 2 ? "Transfers on Etherlink need Layer 2 on and a tz1, tz2 or tz3 account Signet can sign for." : "Signet cannot sign for this account.",
                                  style: "warning-text").row)
        }
        Form.setRows(details, rows)
        details.isVisible = !rows.isEmpty
        passphraseGroup.isVisible = needsPassphrase
    }

    private func updateButtons() {
        switch step {
        case .compose:
            let confirm = button(isBurn ? "Burn" : "Transfer", role: isBurn ? .destructive : .prominent, isDefault: true) { [unowned self] in
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

    /// Everything the estimate depends on: the request itself, and a change of account, network,
    /// node or wallet directory drops the old estimate and asks again (S31).
    private struct EstimateKey: Hashable {
        let request: TokenTransferRequest?
        let context: WalletViewModel.BridgeContext?
        let step: Step
    }

    private func refreshEstimate() async {
        guard step == .compose, let request, model.canTransferTokens(on: operation.layer) else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        render()
        do {
            let result = try await model.estimateTokenTransfer(request, on: operation.layer)
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
            let (hash, level) = try await model.transferTokens(request, on: operation.layer, approved: approved, passphrase: needsPassphrase ? passphrase : nil)
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
