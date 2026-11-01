import CAdwaita
import Foundation

/// Proposes an action from a multisig (a transfer, or a change of delegate) and signs it with one
/// of our keys. The signature is shown for handing to whoever submits; the proposal is kept so more
/// signatures can be gathered. The GTK counterpart of upstream's `Views/SignMultisigSheet.swift`.
@MainActor
final class SignMultisigSheet: Sheet {
    enum Kind: String, CaseIterable, Identifiable {
        case transfer = "Transfer", delegate = "Set delegate", undelegate = "Remove delegate"
        var id: String { rawValue }
    }

    private var contract: MultisigContract?
    private var info: MultisigInfo?
    private var infoError: String?
    private var existing: MultisigProposal?
    private var kind: Kind = .transfer
    private var bakers: [BakerCandidate] = []
    private var signer: Wallet?
    private var isWorking = false
    private var loadTask: Task<Void, Never>?

    private var contractPicker: Widget!
    private let stateBox = UI.hbox(spacing: 0)
    private var proposalPicker: Widget!
    private var shownProposals: [MultisigProposal] = []
    private let kindPicker = Widget(adw_toggle_group_new()!)
    private var amountField: Widget!
    private var destinationField: Widget!
    private var destinationMenu: Widget!
    private var bakerField: Widget!
    private var bakerMenu: Widget!
    private let knownBaker = UI.hbox(spacing: 8)
    private var knownBakerRow: Widget!
    private var undelegateNote: Widget!
    private var signerPicker: Widget!
    private var shownSigners: [Wallet] = []
    private var passphraseField: Widget!
    private var signButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 560)
        if let preset = model.signMultisigPreset {
            contract = preset.contract
            kind = preset.delegating ? .delegate : .transfer
        } else if let selected = model.selectedWallet, selected.address.isContract {
            contract = model.multisigContracts.first { $0.address == selected.address }
        }
        if contract == nil { contract = model.multisigContracts.first }

        guard !model.multisigContracts.isEmpty else {
            content.setChildren([Sheet.title("Sign multisig transaction"),
                                 UI.label("No multisig yet. Use Create multisig… or Add multisig… first.", classes: ["dim-label"], wrap: true)])
            setButtons([cancelButton("Close")])
            return
        }
        let changed: @MainActor () -> Void = { [unowned self] in self.update() }
        let contracts = model.multisigContracts
        contractPicker = Form.picker("Multisig", options: contracts.map { "\($0.alias)  \($0.address.shortened())" },
                                     selected: contracts.firstIndex { $0 == contract } ?? 0) { [unowned self] in
            let index = Form.selected(self.contractPicker)
            guard contracts.indices.contains(index), contracts[index] != self.contract else { return }
            self.contract = contracts[index]
            self.loadInfo()
        }
        proposalPicker = Form.picker("Transaction", options: ["New"], selected: 0) { [unowned self] in
            let index = Form.selected(self.proposalPicker) - 1
            self.existing = self.shownProposals.indices.contains(index) ? self.shownProposals[index] : nil
            self.update()
        }
        for kind in Kind.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, kind.rawValue)
            adw_toggle_set_name(toggle, kind.rawValue)
            adw_toggle_group_add(kindPicker.opaque, toggle)
        }
        adw_toggle_group_set_active_name(kindPicker.opaque, kind.rawValue)
        Signals.connect(kindPicker, "notify::active-name") { [unowned self] in
            guard let name = adw_toggle_group_get_active_name(self.kindPicker.opaque), let kind = Kind(rawValue: String(cString: name)) else { return }
            self.kind = kind
            self.update()
        }
        amountField = Form.entry("Amount (tez)", monospaced: true, onChange: changed)
        destinationField = Form.entry("To (tz1… or KT1…)", monospaced: true, onChange: changed)
        bakerField = Form.entry("Baker (tz1…)", monospaced: true, onChange: changed)
        knownBakerRow = Form.labeled("Baker", content: knownBaker)
        undelegateNote = Form.note("The multisig's tez will no longer be delegated.").row
        signerPicker = Form.picker("Sign with", options: [], selected: 0) { [unowned self] in
            let index = Form.selected(self.signerPicker)
            self.signer = self.shownSigners.indices.contains(index) ? self.shownSigners[index] : nil
            self.update()
        }
        passphraseField = Form.password("Password", onChange: changed)

        let form = Form.group([
            contractPicker, Form.labeled("State", content: stateBox), proposalPicker, Form.row(kindPicker),
            amountField, destinationField, bakerField, knownBakerRow, undelegateNote, signerPicker, passphraseField,
            Form.note("Nothing is sent yet. Your signature goes to whoever submits the transaction, together with the other signers' signatures.").row,
        ])
        content.setChildren([Sheet.title("Sign multisig transaction"), form])
        signButton = button("Sign", role: .prominent, isDefault: true) { [unowned self] in Task { await self.sign() } }
        rebuildMenus()
        loadInfo()
        Task { [weak self, model] in
            let list = await model.bakers()
            guard let self else { return }
            self.bakers = list
            self.rebuildMenus()
            self.update()
        }
    }

    private var amount: Decimal? {
        let text = Form.text(amountField).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }
    private var destinationAddress: Address { Address(Form.text(destinationField).trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var bakerAddress: Address { Address(Form.text(bakerField).trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var signers: [Wallet] { info?.signers(among: model.wallets) ?? [] }
    private var needsPassphrase: Bool { signer?.keyKind == .encrypted }
    private var signsOnLedger: Bool { signer?.keyKind == .ledger }
    private var pending: [MultisigProposal] { model.currentMultisigProposals.filter { $0.contractAddress == contract?.address.value } }
    /// What the form describes, when it is complete.
    private var action: MultisigAction? {
        switch kind {
        case .transfer:
            guard let amount, destinationAddress.isValidAccount else { return nil }
            return .transfer(amountMutez: Mutez.fromTez(amount), destination: destinationAddress.value)
        case .delegate:
            guard bakerAddress.isValidAccount, !bakerAddress.isContract else { return nil }
            return .setDelegate(delegate: bakerAddress.value)
        case .undelegate:
            return .setDelegate(delegate: nil)
        }
    }
    private var canSign: Bool {
        contract != nil && info?.isGenericMultisig == true && signer != nil && !isWorking && !(needsPassphrase && Form.text(passphraseField).isEmpty)
            && (existing != nil || action != nil)
    }

    /// The Choose… menus beside the destination and baker fields.
    private func rebuildMenus() {
        let candidates = model.wallets.filter { $0.address != contract?.address }
        let mine = candidates.filter { $0.keyKind != KeyKind.none }
        let book = candidates.filter { $0.keyKind == KeyKind.none }
        let pick: (Wallet) -> (title: String, enabled: Bool, action: @MainActor () -> Void) = { [unowned self] w in
            ("\(w.alias)  \(w.address.shortened())", true, { @MainActor in Form.setText(self.destinationField, w.address.value) })
        }
        let menu = UI.popoverMenu("Choose…", sections: [(mine.isEmpty ? nil : "My accounts", mine.map(pick)), ("Address book", book.map(pick))].filter { !$0.1.isEmpty })
        if let destinationMenu { gtk_widget_unparent(destinationMenu.pointer) }
        destinationMenu = menu
        Form.addSuffix(menu, to: destinationField)

        let myBakers = model.wallets.filter { $0.keyKind != KeyKind.none && !$0.address.isContract }
        let bakerMenu = UI.popoverMenu("Choose…", sections: [
            ("My accounts", myBakers.map { w in ("\(w.alias)  \(w.address.shortened())", true, { @MainActor [unowned self] in Form.setText(self.bakerField, w.address.value) }) }),
            ("Bakers", bakers.prefix(40).map { b in ("\(b.alias ?? b.address.shortened())  \(b.address.shortened())", true, { @MainActor [unowned self] in Form.setText(self.bakerField, b.address.value) }) }),
        ].filter { !$0.1.isEmpty })
        if let old = self.bakerMenu { gtk_widget_unparent(old.pointer) }
        self.bakerMenu = bakerMenu
        Form.addSuffix(bakerMenu, to: bakerField)
    }

    private func update() {
        guard contractPicker != nil else { return }
        // State.
        if let info {
            stateBox.setChildren([info.isGenericMultisig
                ? UI.label("\(info.threshold) of \(info.keys.count) signatures · \(AssetBalance.format(info.balance, symbol: "tz")) · counter \(info.counter)", xalign: 1)
                : UI.label("Not an octez-client multisig", classes: ["warning-text"])])
        } else if let infoError {
            stateBox.setChildren([UI.label(infoError, classes: ["dim-label"], wrap: true, xalign: 1)])
        } else {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            stateBox.setChildren([spinner])
        }
        // Pending proposals.
        let list = pending
        if list != shownProposals {
            shownProposals = list
            Form.setOptions(proposalPicker, ["New"] + list.map { "\($0.summary) · \($0.signatures.count)/\($0.threshold) signed" },
                            selected: existing.flatMap { e in list.firstIndex { $0.id == e.id }.map { $0 + 1 } } ?? 0)
        }
        proposalPicker.isVisible = !list.isEmpty
        let new = existing == nil
        gtk_widget_set_visible(gtk_widget_get_parent(kindPicker.pointer), new ? 1 : 0)
        amountField.isVisible = new && kind == .transfer
        destinationField.isVisible = new && kind == .transfer
        bakerField.isVisible = new && kind == .delegate
        if bakerAddress.isValidAccount, let known = bakers.first(where: { $0.address == bakerAddress }) {
            knownBaker.setChildren([AccountAvatarView(address: known.address, size: 22).root, UI.label(known.alias ?? known.address.shortened())])
            knownBakerRow.isVisible = new && kind == .delegate
        } else {
            knownBakerRow.isVisible = false
        }
        undelegateNote.isVisible = new && kind == .undelegate
        // Signers.
        let available = signers
        if available != shownSigners || Form.selected(signerPicker) < 0 {
            shownSigners = available
            if signer.map({ !available.contains($0) }) ?? true { signer = available.first }
            Form.setOptions(signerPicker, available.isEmpty ? ["None of your accounts is a signer"] : available.map { "\($0.alias)  \($0.address.shortened())" },
                            selected: signer.flatMap { available.firstIndex(of: $0) } ?? 0)
        }
        passphraseField.isVisible = needsPassphrase
        if let signer { adw_preferences_row_set_title(passphraseField.as(), "Password for “\(signer.alias)”") }

        setBusy(isWorking ? (signsOnLedger ? "Sign on your Ledger…" : "Signing…") : nil)
        canClose = !isWorking
        let cancel = cancelButton()
        cancel.isSensitive = !isWorking
        signButton.isSensitive = canSign
        setButtons([cancel, signButton])
    }

    /// `.task(id: contract)`.
    private func loadInfo() {
        loadTask?.cancel()
        info = nil; infoError = nil; existing = nil
        update()
        guard let contract else { return }
        loadTask = Task {
            do { info = try await model.multisigInfo(contract) } catch { infoError = error.localizedDescription }
            guard !Task.isCancelled else { return }
            signer = signers.first
            shownSigners = []
            rebuildMenus()
            update()
        }
    }

    private func sign() async {
        guard let contract, let signer, canSign else { return }
        setError(nil)
        isWorking = true
        update()
        defer { isWorking = false; if contractPicker != nil { update() } }
        do {
            let proposal: MultisigProposal
            if let existing {
                proposal = existing
            } else {
                guard let action else { return }
                proposal = try await model.proposeMultisig(action, from: contract)
            }
            let signature = try await model.signMultisigProposal(proposal, with: signer, passphrase: needsPassphrase ? Form.text(passphraseField) : nil)
            Form.clear(passphraseField)
            let updated = model.multisigProposals.first { $0.id == proposal.id } ?? proposal
            showDone(updated, signature)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func showDone(_ proposal: MultisigProposal, _ signature: MultisigSignature) {
        contractPicker = nil
        setBusy(nil)
        canClose = true
        let value = UI.label(signature.signature, classes: ["address"], wrap: true).expand(h: true)
        gtk_label_set_selectable(value.opaque, 1)
        content.setChildren([
            Sheet.title("Sign multisig transaction"),
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"),
                                 UI.label("Signed: \(proposal.summary) from “\(proposal.contractAlias)”", classes: ["success-icon"], wrap: true)]),
            UI.label("\(proposal.signatures.count) of \(proposal.threshold) signatures gathered (counter \(proposal.counter)).", classes: ["dim-label"], wrap: true),
            UI.vbox(spacing: 6, [UI.label("Your signature", classes: ["heading"]),
                                 UI.hbox(spacing: 8, [value, UI.copyButton(tooltip: "Copy signature") { signature.signature }.align(v: GTK_ALIGN_START)]).margins(10).classes("card")]),
            UI.label(proposal.isReady
                     ? "Enough signatures: use Submit multisig transaction… to send it."
                     : "Give this signature to whoever will submit, or collect the others' and submit it yourself from Submit multisig transaction….",
                     classes: ["dim-label"], wrap: true),
        ])
        setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
    }

    /// `onDismiss: { model.signMultisigPreset = nil }`.
    override func closed() {
        loadTask?.cancel()
        passphraseField.map(Form.clear)
        model.signMultisigPreset = nil
    }
}
