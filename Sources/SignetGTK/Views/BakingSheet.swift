import CAdwaita
import Foundation

/// Baking: register this wallet as a baker (self-delegate), set its consensus and companion keys,
/// and its staking parameters. Read-only when Signet holds no usable key for the wallet. The GTK
/// counterpart of upstream's `Views/BakingSheet.swift`.
@MainActor
final class BakingSheet: Sheet {
    enum KeyRole { case consensus, companion }
    enum Mode: Equatable { case overview, pickKey(KeyRole), parameters, confirm(StakingOperation), working(StakingOperation), done(hash: String, level: Int, StakingOperation) }

    private var mode: Mode = .overview { didSet { render() } }
    private var estimate: TransferEstimate?
    private var chosenKeyWallet: Wallet?
    /// A pasted tz address resolved to its public key (our record, or the key it revealed on chain).
    private var resolvedKey: (address: Address, key: String, source: WalletViewModel.ResolvedKeySource)?
    /// Why a pasted address gave no key, worded for someone setting up a baker.
    private var lookupNote: String?
    private var lookupTask: Task<Void, Never>?
    private let wallet: Wallet?
    private var heading: Widget!
    private let body = UI.vbox(spacing: 10)
    private var feeValue: Widget?
    // Fields kept across renders.
    private var passphraseField: Widget!
    private var keyPassphraseField: Widget!
    private var pastedKeyField: Widget!
    private var pastedProofField: Widget!
    private var limitField: Widget!
    private var edgeField: Widget!
    private var walletPicker: Widget?
    private var pickerWallets: [Wallet] = []
    private let lookupStatus = UI.hbox(spacing: 6)
    private let proofRows = UI.vbox(spacing: 0)
    private var parametersProblem: Widget!

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 560)
        let header = Sheet.accountTitle("Baking", wallet: wallet)
        heading = header.title
        content.setChildren([header.root, body])
        let changed: @MainActor () -> Void = { [unowned self] in self.updateButtons() }
        passphraseField = Form.password("Password for “\(wallet?.alias ?? "")”", onChange: changed)
        keyPassphraseField = Form.password("Password (to prove possession)", onChange: changed)
        pastedKeyField = Form.entry("Or paste a public key or address", monospaced: true) { [unowned self] in
            if !Form.text(self.pastedKeyField).isEmpty, self.chosenKeyWallet != nil {
                self.chosenKeyWallet = nil
                self.walletPicker.map { Form.select($0, 0) }
            }
            self.pastedKeyChanged()
        }
        pastedProofField = Form.entry("Proof of possession (BLsig…)", monospaced: true, onChange: changed)
        limitField = Form.entry("Limit of staking over baking (× your own stake, 0–9)", monospaced: true, onChange: changed)
        edgeField = Form.entry("Edge of baking over staking (% of stakers' rewards you keep, 0–100)", monospaced: true, onChange: changed)
        parametersProblem = Form.note("The limit must be between 0 and 9 and the edge between 0 and 100.").row
        trackers.append(Tracker { [unowned self] in
            _ = (self.model.delegateInfo, self.model.network)
            if self.mode == .overview { self.render() }
        })
    }

    private var baker: DelegateInfo.Baker? { model.delegateInfo?.baker }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }
    private var canOperate: Bool { wallet?.keyKind.canSign == true }
    /// Quantumnet has no companion keys; consensus keys there may be tz6 (XMSS).
    private var hasCompanionKeys: Bool { model.network.chain != "quantumnet" }
    private var passphrase: String { Form.text(passphraseField) }

    private var title: String {
        switch mode {
        case .overview: "Baking"
        case .pickKey(.consensus): "Set consensus key"
        case .pickKey(.companion): "Set companion key"
        case .parameters: "Staking parameters"
        case .confirm(let op), .working(let op): op.title
        case .done(_, _, let op): "\(op.title): done"
        }
    }

    private func render() {
        UI.setText(heading, title)
        feeValue = nil
        canClose = true
        setBusy(nil)
        switch mode {
        case .overview: body.setChildren(overview())
        case .pickKey(let role): body.setChildren([keyPicker(role)])
        case .parameters: body.setChildren([parametersForm()]); focus(limitField)
        case .confirm(let op): body.setChildren([confirmation(op)])
        case .working(let op):
            canClose = false
            body.setChildren([])
            setBusy(signsOnLedger ? "\(op.title): confirm on your Ledger, then we wait for the next block…" : "\(op.title)… waiting for the next block")
        case .done(let hash, let level, _):
            body.setChildren([UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                                   UI.label("Included in block \(level.formatted())", classes: ["success-icon"])]),
                              OperationLink.make(hash, network: model.network)])
        }
        updateButtons()
    }

    // MARK: Overview

    private func section(_ title: String, _ rows: [Widget]) -> Widget {
        UI.vbox(spacing: 6, [UI.label(title, classes: ["heading"]), Form.group(rows)])
    }

    private func overview() -> [Widget] {
        var sections: [Widget] = []
        if !canOperate { sections.append(Form.group([Form.note(watchOnlyNote, icon: "view-reveal-symbolic").row])) }
        var bakerRows: [Widget] = []
        if model.delegateInfo == nil {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            bakerRows.append(Form.row(spinner.align(h: GTK_ALIGN_START)))
        } else if let baker {
            bakerRows.append(Form.labeled("Status", value: baker.deactivated ? "Registered, deactivated" : "Registered, active").row)
            if let grace = baker.gracePeriod { bakerRows.append(Form.labeled("Grace period until cycle", value: "\(grace)").row) }
            if baker.deactivated {
                bakerRows.append(Form.note(canOperate
                    ? "The chain deactivated this baker because it missed its baking and attesting duties for a few cycles. Reactivating registers it again, the same operation as the first time; rights return after the usual delay, and the baker daemon must be running to keep them."
                    : "The chain deactivated this baker because it missed its baking and attesting duties for a few cycles. Register it again from where its key lives to reactivate it.").row)
                if canOperate { bakerRows.append(actionRow("Reactivate…") { [unowned self] in self.startConfirm(.reactivateBaker) }) }
            }
        } else {
            bakerRows.append(Form.note(canOperate
                ? "This account is not a baker. Registering self-delegates it; baking rights need at least the protocol's minimum stake and a running baker daemon."
                : "This address is not a baker.").row)
            if canOperate { bakerRows.append(actionRow("Register as a baker…") { [unowned self] in self.startConfirm(.registerAsBaker) }) }
        }
        sections.append(section("Baker", bakerRows))

        guard let baker else { return sections }
        var consensus = keyRows(current: baker.consensusKey, pending: baker.pendingConsensusKeys, fallback: "Baker's own key")
        if canOperate { consensus.append(actionRow("Set consensus key…") { [unowned self] in self.resetKeyPicker(); self.mode = .pickKey(.consensus) }) }
        consensus.append(Form.note(hasCompanionKeys
            ? "The key the baker daemon signs blocks and attestations with. A tz4 (BLS) key needs its proof of possession."
            : "The key the baker daemon signs with. On Quantumnet this can be a post-quantum tz6 (XMSS) key.").row)
        sections.append(section("Consensus key", consensus))

        if hasCompanionKeys {
            var companion = keyRows(current: baker.companionKey, pending: baker.pendingCompanionKeys, fallback: "None")
            if canOperate { companion.append(actionRow("Set companion key…") { [unowned self] in self.resetKeyPicker(); self.mode = .pickKey(.companion) }) }
            companion.append(Form.note("A tz4 (BLS) key used for DAL attestations alongside a non-BLS consensus key.").row)
            sections.append(section("Companion key", companion))
        }

        var parameters: [Widget] = []
        if let p = baker.stakingParameters {
            parameters.append(Form.labeled("Limit of staking over baking", value: "\(formatted(p.limitMultiplier))×").row)
            parameters.append(Form.labeled("Edge of baking over staking", value: "\(formatted(p.edgePercent)) %").row)
        } else {
            parameters.append(Form.labeled("Active", value: "Defaults (no staking accepted)").row)
        }
        for p in baker.pendingStakingParameters {
            parameters.append(Form.labeled("Pending from cycle \(p.cycle.map(String.init) ?? "?")", value: "\(formatted(p.limitMultiplier))× · \(formatted(p.edgePercent)) %").row)
        }
        if canOperate {
            parameters.append(actionRow("Change…") { [unowned self] in
                Form.setText(self.limitField, self.formatted(baker.stakingParameters?.limitMultiplier ?? 0))
                Form.setText(self.edgeField, self.formatted(baker.stakingParameters?.edgePercent ?? 0))
                self.mode = .parameters
            })
        }
        parameters.append(Form.note("The limit caps how much stake you accept from others, as a multiple of your own (0 = none, up to 9×). The edge is the share of stakers' rewards you keep (0 to 100 %). Changes apply after a few cycles.").row)
        sections.append(section("Staking parameters", parameters))
        return sections
    }

    private func actionRow(_ title: String, _ action: @escaping @MainActor () -> Void) -> Widget {
        Form.row(UI.button(title, action: action).align(h: GTK_ALIGN_START))
    }

    private var watchOnlyNote: String {
        switch wallet?.keyKind {
        case .remote: "Watch only: this baker signs through a remote signer. Its keys and parameters are shown but cannot be changed here."
        default: "Watch only: Signet holds just this baker's public key. Its keys and parameters are shown but cannot be changed here."
        }
    }

    private func keyRows(current: Address?, pending: [Address], fallback: String) -> [Widget] {
        let active: Widget
        if let current {
            active = UI.hbox(spacing: 6, [AccountAvatarView(address: current, size: 20).root, UI.label(model.displayName(for: current, indexerAlias: nil).name),
                                          UI.label(current.shortened(), classes: ["address", "dim-label"])])
        } else {
            active = UI.label(fallback, classes: ["dim-label"])
        }
        return [Form.labeled("Active", content: active)] + pending.map { Form.labeled("Pending", content: UI.label($0.shortened(), classes: ["address", "dim-label"])) }
    }

    // MARK: Key picker

    private func resetKeyPicker() {
        lookupTask?.cancel(); lookupTask = nil
        chosenKeyWallet = nil
        resolvedKey = nil; lookupNote = nil
        for field in [pastedKeyField!, pastedProofField!, keyPassphraseField!] { Form.clear(field) }
    }

    /// The pasted field, read as a key or an address.
    private var pastedContent: WalletViewModel.KeyFieldContent { WalletViewModel.keyFieldContent(Form.text(pastedKeyField)) }

    /// Looks up the key behind a pasted tz address. A key, or anything else, is passed on as typed:
    /// the chain or the bridge refuses what is not a key, and tz6 (xmpk) keys are only ever pasted.
    private func pastedKeyChanged() {
        lookupTask?.cancel(); lookupTask = nil
        resolvedKey = nil; lookupNote = nil
        defer { updateKeyPicker() }
        guard case .address(let address) = pastedContent else { return }
        chosenKeyWallet = nil
        lookupTask = Task {
            defer { if !Task.isCancelled { updateKeyPicker() } }
            do {
                let found = try await model.publicKey(forKeyOrAddress: address.value)
                guard !Task.isCancelled, pastedContent == .address(address) else { return }
                resolvedKey = (address, found.key, found.source)
            } catch WalletViewModel.MultisigError.notRevealed {
                guard !Task.isCancelled, pastedContent == .address(address) else { return }
                lookupNote = "\(address.shortened()) has not revealed a public key on \(model.network.name). That is usual for a new consensus or companion key: it has never sent an operation, so the chain does not know it. Paste the public key itself instead; on the machine that holds the key, octez-client show address <alias> prints it."
            } catch {
                guard !Task.isCancelled, pastedContent == .address(address) else { return }
                lookupNote = error.localizedDescription
            }
        }
    }

    private func updateLookupStatus() {
        guard case .address = pastedContent else { lookupStatus.setChildren([]); lookupStatus.isVisible = false; return }
        lookupStatus.isVisible = true
        if let resolvedKey {
            let origin = switch resolvedKey.source {
            case .ownAccount(let alias): "the key of your account “\(alias)”"
            case .revealedOnChain: "the key it revealed on \(model.network.name)"
            case .pasted: "the key"
            }
            lookupStatus.setChildren([UI.label("\(resolvedKey.address.shortened()) is \(origin): \(resolvedKey.key.prefix(12))…", classes: ["dim-label"], wrap: true)])
        } else if let lookupNote {
            lookupStatus.setChildren([UI.label(lookupNote, classes: ["warning-text"], wrap: true)])
        } else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            lookupStatus.setChildren([spinner, UI.label("Looking up the key this address revealed…", classes: ["dim-label"])])
        }
    }

    private func eligibleWallets(_ role: KeyRole) -> [Wallet] {
        model.wallets.filter { w in
            guard w.publicKey != nil, w.address != wallet?.address else { return false }
            return role == .companion ? w.scheme == .tz4 : true   // consensus: any scheme the network allows
        }
    }

    private var pickedPublicKey: String? {
        if let pk = chosenKeyWallet?.publicKey { return pk }
        switch pastedContent {
        case .empty: return nil
        case .publicKey(let key), .other(let key): return key
        case .address(let address): return resolvedKey?.address == address ? resolvedKey?.key : nil
        }
    }
    private var pickedIsBLS: Bool { pickedPublicKey?.hasPrefix("BLpk") == true }
    private var proofNeeded: Bool { pickedIsBLS }
    private var proofAvailable: Bool {
        guard proofNeeded else { return true }
        if let w = chosenKeyWallet, w.scheme == .tz4, w.keyKind.canSign { return w.keyKind != .encrypted || !Form.text(keyPassphraseField).isEmpty }
        return !Form.text(pastedProofField).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func keyPicker(_ role: KeyRole) -> Widget {
        pickerWallets = eligibleWallets(role)
        let picker = Form.picker("From your accounts", options: ["Choose…"] + pickerWallets.map { w in
            "\(w.alias)  \(w.address.shortened())  (\(w.scheme.rawValue)\(w.keyKind.canSign ? "" : ", public key only"))"
        }, selected: 0) { [unowned self] in
            let index = Form.selected(self.walletPicker!) - 1
            self.chosenKeyWallet = self.pickerWallets.indices.contains(index) ? self.pickerWallets[index] : nil
            if self.chosenKeyWallet != nil, !Form.text(self.pastedKeyField).isEmpty { Form.clear(self.pastedKeyField) }
            self.updateKeyPicker()
        }
        walletPicker = picker
        adw_preferences_row_set_title(pastedKeyField.as(), role == .companion ? "Or paste a public key or address (BLpk… or tz4…)"
                                                                               : "Or paste a public key or address (edpk… / sppk… / p2pk… / BLpk… / mdpk… / xmpk… or a tz address)")
        updateKeyPicker()
        return Form.group([
            picker, pastedKeyField, Form.row(lookupStatus), Form.row(proofRows),
            Form.note(role == .consensus ? "Takes effect after the consensus-rights delay (a few cycles)." : "Companion keys must be tz4 (BLS).").row,
        ])
    }

    private func updateKeyPicker() {
        updateLookupStatus()
        gtk_widget_set_visible(gtk_widget_get_parent(lookupStatus.pointer), lookupStatus.isVisible ? 1 : 0)
        var proof: [Widget] = []
        if proofNeeded {
            if let w = chosenKeyWallet, w.scheme == .tz4, w.keyKind.canSign {
                if w.keyKind == .encrypted {
                    adw_preferences_row_set_title(keyPassphraseField.as(), "Password for “\(w.alias)” (to prove possession)")
                    proof.append(Form.group([keyPassphraseField]))
                } else {
                    proof.append(UI.label("Signet will produce the BLS proof of possession from this account's key.", classes: ["dim-label"], wrap: true))
                }
            } else {
                proof.append(Form.group([pastedProofField]))
                proof.append(UI.label("BLS keys must prove possession. Paste the proof made where the key lives, e.g. octez-client's BLS proof for that key.", classes: ["dim-label"], wrap: true))
            }
        }
        proofRows.setChildren(proof)
        gtk_widget_set_visible(gtk_widget_get_parent(proofRows.pointer), proof.isEmpty ? 0 : 1)
        proofRows.isVisible = !proof.isEmpty
        updateButtons()
    }

    // MARK: Parameters

    private func parametersForm() -> Widget {
        Form.group([limitField, edgeField, parametersProblem,
                    Form.note("Set the limit to 0 to stop accepting new stake. Changes take effect after a few cycles.").row])
    }

    private var parsedParameters: StakingParameters? {
        func decimal(_ s: String) -> Decimal? { Decimal(string: s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) }
        guard let limit = decimal(Form.text(limitField)), let edge = decimal(Form.text(edgeField)) else { return nil }
        return StakingParameters(limitMultiplier: limit, edgePercent: edge)
    }

    private func formatted(_ d: Decimal) -> String {
        let f = NumberFormatter(); f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
        return f.string(from: d as NSDecimalNumber) ?? "\(d)"
    }

    // MARK: Confirm

    private func confirmation(_ op: StakingOperation) -> Widget {
        var rows = [Form.labeled("Operation", value: op.title).row]
        switch op {
        case .updateConsensusKey(let pk, _), .updateCompanionKey(let pk, _):
            let key = UI.label(pk, classes: ["address"], xalign: 1)
            gtk_label_set_ellipsize(key.opaque, PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(key.opaque, 36)
            rows.append(Form.labeled("Public key", content: key))
        case .setStakingParameters(let p, _):
            rows.append(Form.labeled("Limit", value: "\(formatted(p.limitMultiplier))×").row)
            rows.append(Form.labeled("Edge", value: "\(formatted(p.edgePercent)) %").row)
        default: break
        }
        let fee = UI.hbox(spacing: 0)
        feeValue = fee
        updateFee()
        rows.append(Form.labeled("Fee", content: fee))
        if needsPassphrase { rows.append(passphraseField); focus(passphraseField) }
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
        let back = button("Back") { [unowned self] in self.setError(nil); self.mode = .overview }
        switch mode {
        case .overview:
            setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        case .pickKey(let role):
            let next = button("Continue", role: .prominent, isDefault: true) { [unowned self] in Task { await self.prepareKeyUpdate(role) } }
            next.isSensitive = pickedPublicKey != nil && proofAvailable && !(role == .companion && !pickedIsBLS)
            setButtons([back, next])
        case .parameters:
            let parsed = parsedParameters
            parametersProblem.isVisible = parsed == nil && !Form.text(limitField).isEmpty && !Form.text(edgeField).isEmpty
            let next = button("Continue", role: .prominent, isDefault: true) { [unowned self] in
                if let p = self.parsedParameters, let wallet = self.wallet { self.startConfirm(.setStakingParameters(p, source: wallet.address)) }
            }
            next.isSensitive = parsed != nil
            setButtons([back, next])
        case .confirm(let op):
            let confirm = button("Confirm", role: .prominent, isDefault: true) { [unowned self] in Task { await self.perform(op) } }
            confirm.isSensitive = estimate != nil && !(needsPassphrase && passphrase.isEmpty)
            setButtons([back, confirm])
        case .working:
            setButtons([])
        case .done:
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        }
    }

    private func prepareKeyUpdate(_ role: KeyRole) async {
        setError(nil)
        guard let publicKey = pickedPublicKey else { return }
        do {
            var proof: String?
            if pickedIsBLS {
                if let keyWallet = chosenKeyWallet, keyWallet.scheme == .tz4, keyWallet.keyKind.canSign {
                    proof = try await model.proofOfPossession(for: keyWallet, passphrase: keyWallet.keyKind == .encrypted ? Form.text(keyPassphraseField) : nil)
                } else {
                    proof = Form.text(pastedProofField).trimmingCharacters(in: .whitespaces)
                }
            }
            startConfirm(role == .consensus ? .updateConsensusKey(publicKey: publicKey, proof: proof) : .updateCompanionKey(publicKey: publicKey, proof: proof))
        } catch {
            setError(error.localizedDescription)
        }
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
        mode = .working(op)
        do {
            let result = try await model.performStaking(op, limits: estimate?.limits, passphrase: needsPassphrase ? passphrase : nil)
            Form.clear(passphraseField)
            mode = .done(hash: result.hash, level: result.level, op)
        } catch {
            setError(error.localizedDescription)
            mode = .confirm(op)
        }
    }

    override func closed() {
        lookupTask?.cancel()
        Form.clear(passphraseField)
        Form.clear(keyPassphraseField)
    }
}
