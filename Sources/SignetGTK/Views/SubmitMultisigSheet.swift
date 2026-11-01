import CAdwaita
import Foundation

/// Gathers the other signers' signatures on a proposal and submits it from one of our accounts.
/// The GTK counterpart of upstream's `Views/SubmitMultisigSheet.swift`.
@MainActor
final class SubmitMultisigSheet: Sheet {
    private var proposalID: MultisigProposal.ID?
    private var submitter: Wallet?
    private var estimate: MultisigEstimate?
    private var estimateTask: Task<Void, Never>?
    /// What the estimate was made for (`.task(id:)` upstream).
    private var estimated: String?
    private var isWorking = false
    private var done = false

    private var proposalPicker: Widget!
    private var shownProposals: [MultisigProposal] = []
    private let details = Form.group([])
    private let pasteView = Widget(gtk_text_view_new()!)
    private var submitterPicker: Widget!
    private var passphraseField: Widget!
    private var submitButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 580)
        guard !proposals.isEmpty else {
            content.setChildren([Sheet.title("Submit multisig transaction"),
                                 UI.label("No pending multisig transaction on \(model.network.name). Propose one with Sign multisig transaction… first.", classes: ["dim-label"], wrap: true)])
            setButtons([cancelButton("Close")])
            return
        }
        proposalID = proposals.first?.id
        submitter = submitters.first
        proposalPicker = Form.picker("Transaction", options: [], selected: 0) { [unowned self] in
            let index = Form.selected(self.proposalPicker)
            if self.shownProposals.indices.contains(index) { self.proposalID = self.shownProposals[index].id }
            self.update()
        }
        let list = submitters
        submitterPicker = Form.picker("Submit from", options: list.map { "\($0.alias)  \($0.address.shortened())" }, selected: 0) { [unowned self] in
            let index = Form.selected(self.submitterPicker)
            self.submitter = list.indices.contains(index) ? list[index] : nil
            self.update()
        }
        passphraseField = Form.password("Password", onChange: { [unowned self] in self.update() })
        gtk_text_view_set_wrap_mode(pasteView.as(), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(pasteView.as(), 1)
        pasteView.size(height: 60).classes("phrase-editor")
        let addSignatures = UI.button("Add signatures") { [unowned self] in self.addPasted() }.align(h: GTK_ALIGN_END)
        let paste = Form.row(UI.vbox(spacing: 6, [UI.label("Paste the other signers' signatures (one per line or separated by spaces)", wrap: true), pasteView, addSignatures]))

        content.setChildren([
            Sheet.title("Submit multisig transaction"),
            Form.group([proposalPicker]), details,
            Form.group([paste, submitterPicker, passphraseField,
                        Form.note("The submitting account pays the fee; the multisig does the rest. Signatures are checked against the multisig's keys before anything is sent.").row]),
        ])
        submitButton = button("Submit", role: .prominent, isDefault: true) { [unowned self] in Task { await self.submit() } }
        trackers.append(Tracker { [unowned self] in self.update() })
    }

    private var proposals: [MultisigProposal] { model.currentMultisigProposals }
    private var proposal: MultisigProposal? { proposals.first { $0.id == proposalID } }
    private var submitters: [Wallet] { model.wallets.filter { $0.keyKind.canSign && $0.publicKey != nil } }
    private var needsPassphrase: Bool { submitter?.keyKind == .encrypted }
    private var signsOnLedger: Bool { submitter?.keyKind == .ledger }
    private var canSubmit: Bool {
        proposal?.isReady == true && submitter != nil && estimate != nil && !isWorking && !(needsPassphrase && Form.text(passphraseField).isEmpty)
    }

    private func update() {
        guard !done, proposalPicker != nil else { return }
        let list = proposals
        if list != shownProposals {
            shownProposals = list
            if proposal == nil { proposalID = list.first?.id }
            Form.setOptions(proposalPicker, list.map { "\($0.summary) from \($0.contractAlias) · counter \($0.counter)" },
                            selected: list.firstIndex { $0.id == proposalID } ?? 0)
        }
        var rows: [Widget] = []
        if let proposal {
            rows.append(Form.labeled("Signatures", value: "\(proposal.signatures.count) of \(proposal.threshold) needed").row)
            for sig in proposal.signatures {
                let who: Widget
                if let pk = sig.publicKey, let mine = model.wallets.first(where: { $0.publicKey == pk }) {
                    who = UI.hbox(spacing: 4, [UI.image(icon: "object-select-symbolic", pixelSize: 12), UI.label(mine.alias)])
                } else {
                    who = UI.label("pasted", classes: ["dim-label"])
                }
                rows.append(Form.row(UI.hbox(spacing: 8, [who, UI.label(sig.signature.prefix(16) + "…", classes: ["address", "dim-label"])])))
            }
            if proposal.isReady {
                if let estimate {
                    rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
                } else {
                    let spinner = Widget(gtk_spinner_new()!)
                    gtk_spinner_start(spinner.opaque)
                    rows.append(Form.labeled("Fee", content: spinner))
                }
            } else {
                rows.append(Form.note("\(proposal.missing) more signature\(proposal.missing == 1 ? "" : "s") needed before this can be submitted.").row)
            }
        }
        Form.setRows(details, rows)
        passphraseField.isVisible = needsPassphrase
        if let submitter { adw_preferences_row_set_title(passphraseField.as(), "Password for “\(submitter.alias)”") }
        refreshEstimate()

        setBusy(isWorking ? (signsOnLedger ? "Confirm on your Ledger…" : "Submitting…") : nil)
        canClose = !isWorking
        var list2: [Widget] = []
        if let proposal, !isWorking {
            list2.append(button("Discard proposal", role: .destructive) { [unowned self] in
                try? self.model.removeMultisigProposal(proposal)
                self.proposalID = self.proposals.first?.id
                self.update()
            })
        }
        let cancel = cancelButton()
        cancel.isSensitive = !isWorking
        submitButton.isSensitive = canSubmit
        setButtons(list2 + [cancel, submitButton])
    }

    private func addPasted() {
        guard let proposal else { return }
        setError(nil)
        let buffer = gtk_text_view_get_buffer(pasteView.as())
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return }
        let pasted = String(cString: raw)
        g_free(raw)
        for token in pasted.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            do { try model.addMultisigSignature(String(token), to: proposal) } catch { setError(error.localizedDescription) }
        }
        gtk_text_buffer_set_text(buffer, "", 0)
    }

    /// `.task(id: proposal, its signature count, submitter)`.
    private func refreshEstimate() {
        let key = "\(proposalID?.uuidString ?? "")-\(proposal?.signatures.count ?? 0)-\(submitter?.id ?? "")"
        guard key != estimated else { return }
        estimated = key
        estimateTask?.cancel()
        estimate = nil
        guard let proposal, proposal.isReady, let submitter else { return }
        setError(nil)
        estimateTask = Task {
            do {
                let found = try await model.estimateSubmitMultisig(proposal, from: submitter)
                guard !Task.isCancelled else { return }
                estimate = found
            } catch {
                guard !Task.isCancelled else { return }
                setError(error.localizedDescription)
            }
            update()
        }
    }

    private func submit() async {
        guard let proposal, let submitter, canSubmit else { return }
        setError(nil)
        isWorking = true
        update()
        defer { isWorking = false; update() }
        do {
            let hash = try await model.submitMultisig(proposal, from: submitter, limits: estimate?.limits, passphrase: needsPassphrase ? Form.text(passphraseField) : nil)
            Form.clear(passphraseField)
            showDone(hash)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func showDone(_ hash: String) {
        done = true
        setBusy(nil)
        canClose = true
        content.setChildren([
            Sheet.title("Submit multisig transaction"),
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"), UI.label("Submitted and included in a block", classes: ["success-icon"])]),
            OperationLink.make(hash, network: model.network),
        ])
        setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
    }

    override func closed() {
        estimateTask?.cancel()
        passphraseField.map(Form.clear)
    }
}
