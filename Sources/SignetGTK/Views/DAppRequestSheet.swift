import CAdwaita
import Foundation

/// Approves or rejects the dApp request at the front of the queue. The GTK counterpart of
/// upstream's `Views/DAppRequestSheet.swift`; Escape does not close it
/// (`.interactiveDismissDisabled()`), a request is answered with Reject or Approve.
@MainActor
final class DAppRequestSheet: Sheet {
    let request: DAppRequest
    private var chosenWallet: Wallet?
    private var summaries: [DAppOperationSummary] = []
    private var prepared: DAppPreparedBatch?
    private var prepareError: String?
    private var showsParameters: Set<Int> = []
    private var isWorking = false
    private var prepareTask: Task<Void, Never>?
    private let body = UI.vbox(spacing: 0)
    private let dappError = UI.label(classes: ["error-text"], wrap: true)
    private var passphraseField: Widget!
    private var walletChoices: [Wallet] = []
    private var walletPicker: Widget?
    private var approveButton: Widget!

    init(model: WalletViewModel, request: DAppRequest) {
        self.request = request
        super.init(model: model, width: 520)
        canClose = false
        dapps.clearMessages()
        chosenWallet = model.selectedWallet.flatMap { $0.publicKey != nil && $0.keyKind.canSign ? $0 : nil }
            ?? model.wallets.first { $0.publicKey != nil && $0.keyKind.canSign }
        passphraseField = Form.password("Password", onChange: { [unowned self] in self.updateButtons() })

        var host: [Widget] = [UI.label(request.app.name)]
        if let url = request.app.url { host.append(UI.label(url.host() ?? url.absoluteString, classes: ["dim-label"])) }
        let header = UI.hbox(spacing: 12, [DAppIconView.make(url: request.app.icon, size: 44),
                                           UI.vbox(spacing: 2, [Sheet.title(title), UI.hbox(spacing: 6, host)]).align(v: GTK_ALIGN_CENTER)])
        content.setChildren([header, body, dappError])
        approveButton = button(approveTitle, role: .prominent, isDefault: true) { [unowned self] in self.approve() }
        trackers.append(Tracker { [unowned self] in self.update() })

        // `.task(id: request.id)`.
        if case .operation(_, _, _, _, _, let json) = request {
            prepareTask = Task {
                summaries = await dapps.summaries(for: json)
                render()
                // Simulate the batch so the exact fee, burn and totals are known; approval waits for this.
                do { prepared = try await dapps.prepare(request) } catch { prepareError = error.localizedDescription }
                guard !Task.isCancelled else { return }
                render()
            }
        }
    }

    private var dapps: DAppConnectionManager { model.dapps }

    private var title: String {
        switch request {
        case .permission: "Connection request"
        case .operation: "Approve operation"
        case .signPayload: "Sign message"
        case .unsupported: "Unsupported request"
        }
    }

    /// Follows the manager: the reply may become undelivered, an error may arrive.
    private var shownUndelivered: Bool?

    private func update() {
        let undelivered = dapps.undelivered[request.id] != nil
        if undelivered != shownUndelivered {
            shownUndelivered = undelivered
            render()
        }
        if let error = dapps.lastError {
            UI.setText(dappError, error)
            dappError.isVisible = true
        } else {
            dappError.isVisible = false
        }
        updateButtons()
    }

    private func render() {
        if let reply = dapps.undelivered[request.id] {
            body.setChildren([undeliveredView(reply)])
        } else {
            body.setChildren([contentView()])
        }
        updateButtons()
    }

    /// The work is done; only the reply to the dApp is outstanding (S17). Nothing can be redone here.
    private func undeliveredView(_ reply: DAppConnectionManager.UndeliveredReply) -> Widget {
        UI.vbox(spacing: 10, [
            UI.hbox(spacing: 8, [UI.image(icon: "object-select-symbolic").classes("success-icon"), UI.label(reply.summary, classes: ["success-icon"], wrap: true)]),
            UI.label("The dApp has not received the reply yet (\(reply.attempts) attempt\(reply.attempts == 1 ? "" : "s")). Send the reply again when the relay is back, or dismiss this and tell the dApp yourself. Nothing is signed or sent again either way.",
                     classes: ["dim-label"], wrap: true),
        ])
    }

    private func contentView() -> Widget {
        switch request {
        case .permission(_, _, let networkType, let rpcURL, let scopes):
            walletChoices = model.wallets.filter { $0.publicKey != nil && $0.keyKind.canSign }
            let picker = Form.picker("Share account", options: walletChoices.map { "\($0.alias)  \($0.address.shortened())" },
                                     selected: chosenWallet.flatMap { walletChoices.firstIndex(of: $0) } ?? 0) { [unowned self] in
                let index = Form.selected(self.walletPicker!)
                self.chosenWallet = self.walletChoices.indices.contains(index) ? self.walletChoices[index] : nil
                self.updateButtons()
            }
            walletPicker = picker
            var rows = [picker,
                        Form.labeled("Network", value: networkType + (rpcURL.map { " (\($0.host() ?? ""))" } ?? "")).row,
                        Form.labeled("Permissions", value: scopes.map(scopeName).joined(separator: ", "), wrap: true).row]
            if DAppRequest.network(forType: networkType, rpcURL: rpcURL) == nil {
                rows.append(Form.note("Signet has no node for this network; operations from this dApp will fail.", icon: "dialog-warning-symbolic", style: "warning-text").row)
            }
            rows.append(Form.note("The dApp will see this account's address and public key, and can ask you to approve operations and signatures. Nothing happens without your approval here.").row)
            return Form.group(rows)

        case .operation(_, _, let networkType, let rpcURL, let source, _):
            var rows = [sourceRow(source), networkRow(networkType, rpcURL)]
            let shown = prepared?.operations ?? summaries
            if shown.isEmpty {
                rows.append(Form.labeled("Operations", content: spinner()))
            } else {
                rows += shown.enumerated().map { operationRow($0.offset, $0.element) }
            }
            rows += costRows()
            rows += passphraseRows(for: source)
            if let prepareError {
                rows.append(Form.note(prepareError, icon: "dialog-error-symbolic", style: "error-text").row)
                rows.append(Form.note("The node could not simulate this batch, so it cannot be approved.").row)
            } else if prepared == nil {
                rows.append(Form.note("Simulating on the node to get the exact fee and effects…").row)
            } else {
                rows.append(Form.note("Fee and storage are what the node's simulation says this exact batch costs. Approving signs the batch exactly as shown; the dApp's own fee, gas and storage figures are not used.").row)
            }
            return Form.group(rows)

        case .signPayload(_, _, let source, let signingType, let payload):
            let message = UI.label(decodedPayload(payload, signingType: signingType), classes: ["address"], wrap: true)
            gtk_label_set_selectable(message.opaque, 1)
            var rows = [sourceRow(source), Form.labeled("Type", value: signingType).row,
                        Form.stacked("Message", below: [scrolled(message, maxHeight: 140)])]
            rows += passphraseRows(for: source)
            rows.append(Form.note("Signing proves you control this account. Only sign messages you understand from dApps you trust. Signet signs packed Michelson messages only, never operations.").row)
            return Form.group(rows)

        case .unsupported(_, _, let type):
            return UI.label("Signet cannot handle “\(type)” requests yet.", classes: ["dim-label"], wrap: true)
        }
    }

    private func spinner() -> Widget {
        let spinner = Widget(gtk_spinner_new()!)
        gtk_spinner_start(spinner.opaque)
        return spinner
    }

    private func scrolled(_ child: Widget, maxHeight: Int32) -> Widget {
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(scroller.opaque, 1)
        gtk_scrolled_window_set_max_content_height(scroller.opaque, maxHeight)
        gtk_scrolled_window_set_child(scroller.opaque, child.pointer)
        return scroller
    }

    private func operationRow(_ index: Int, _ op: DAppOperationSummary) -> Widget {
        var values: [Widget] = []
        if let amount = op.amount, amount > 0 { values.append(UI.label(AssetBalance.format(amount, symbol: "tz"), classes: ["numeric"], xalign: 1)) }
        if let destination = op.destination { values.append(UI.label(destination, classes: ["address", "dim-label"], wrap: true, xalign: 1)) }
        if let entrypoint = op.entrypoint { values.append(UI.label("entrypoint \(entrypoint)", classes: ["dim-label", "caption"], xalign: 1)) }
        if let delegate = op.delegate { values.append(UI.label("to \(delegate)", classes: ["address", "dim-label"], wrap: true, xalign: 1)) }
        if let fee = op.fee {
            values.append(UI.label("fee \(AssetBalance.format(fee, symbol: "tz"))\(op.burn.map { $0 > 0 ? " · storage \(AssetBalance.format($0, symbol: "tz"))" : "" } ?? "")", classes: ["dim-label", "caption"], xalign: 1))
        }
        var lines = [UI.hbox(spacing: 12, [UI.label(op.kind.capitalized).expand(h: true).align(v: GTK_ALIGN_START), UI.vbox(spacing: 2, values)])]
        for effect in op.effects {
            lines.append(note(effect.text, icon: effect.warning ? "dialog-warning-symbolic" : "help-about-symbolic", style: effect.warning ? "warning-text" : "dim-label"))
        }
        if op.opaque {
            lines.append(note("Signet cannot tell what this contract call does. Approve it only if you trust the dApp; the parameters are below.", icon: "dialog-warning-symbolic", style: "warning-text"))
        }
        if let requested = op.requestedFee {
            lines.append(note("The dApp asked for a \(AssetBalance.format(requested, symbol: "tz")) fee; Signet pays the node's estimate instead.", icon: "help-about-symbolic", style: "dim-label"))
        }
        if let parameters = op.parameters {
            let text = UI.label(parameters, classes: ["address", "caption"], wrap: true)
            gtk_label_set_selectable(text.opaque, 1)
            let expander = Widget(gtk_expander_new("Parameters")!)
            gtk_expander_set_child(expander.opaque, scrolled(text, maxHeight: 160).pointer)
            gtk_expander_set_expanded(expander.opaque, showsParameters.contains(index) ? 1 : 0)
            Signals.connect(expander, "notify::expanded") { [unowned self] in
                if gtk_expander_get_expanded(expander.opaque) != 0 { self.showsParameters.insert(index) } else { self.showsParameters.remove(index) }
            }
            lines.append(expander)
        }
        return Form.row(UI.vbox(spacing: 4, lines))
    }

    private func note(_ text: String, icon: String, style: String) -> Widget {
        UI.hbox(spacing: 6, [UI.image(icon: icon, pixelSize: 14).align(v: GTK_ALIGN_START), UI.label(text, wrap: true).expand(h: true)]).classes(style)
    }

    private func costRows() -> [Widget] {
        guard let prepared else {
            return prepareError == nil ? [Form.labeled("Fee", content: spinner())] : []
        }
        var rows: [Widget] = []
        if let revealFee = prepared.revealFee {
            rows.append(Form.labeled("Reveal", value: "fee \(AssetBalance.format(revealFee, symbol: "tz")) (first operation from this account)", wrap: true).row)
        }
        rows.append(Form.labeled("Fee", value: AssetBalance.format(prepared.totalFee, symbol: "tz")).row)
        if prepared.totalBurn > 0 { rows.append(Form.labeled("Storage", value: AssetBalance.format(prepared.totalBurn, symbol: "tz")).row) }
        let total = Form.labeled("Total leaving the account", value: AssetBalance.format(prepared.totalDebit, symbol: "tz"))
        total.value.classes("heading")
        rows.append(total.row)
        return rows
    }

    /// The network by name, and for a dApp-chosen endpoint the exact host, port and path it
    /// points at: a name is not a chain, so the user sees where the batch would really go (S12).
    private func networkRow(_ networkType: String, _ rpcURL: URL?) -> Widget {
        guard let network = DAppRequest.network(forType: networkType, rpcURL: rpcURL) else {
            return Form.labeled("Network", content: UI.label("\(networkType)\(rpcURL.map { " at \(DAppRequest.endpointDescription($0))" } ?? "") is not a network Signet will use",
                                                         classes: ["warning-text"], wrap: true, xalign: 1))
        }
        var lines = [UI.label(network.name, xalign: 1)]
        if network.chain == "custom" || !network.isUsingDefaultNode {
            lines.append(UI.label(DAppRequest.endpointDescription(network.rpcURL), classes: ["address", "dim-label", "caption"], xalign: 1))
        }
        if network.expectedChainID == nil {
            lines.append(UI.label("chain not pinned; the node is trusted to serve \(network.name)", classes: ["dim-label", "caption"], wrap: true, xalign: 1))
        }
        return Form.labeled("Network", content: UI.vbox(spacing: 2, lines))
    }

    private func sourceRow(_ source: Address) -> Widget {
        var children = [AccountAvatarView(address: source, size: 22).root]
        if let wallet = dapps.wallet(for: source) {
            children += [UI.label(wallet.alias), UI.label(source.shortened(), classes: ["address", "dim-label"])]
        } else {
            children.append(UI.label("\(source.shortened()) is not one of your accounts", classes: ["warning-text"], wrap: true))
        }
        return Form.labeled("Account", content: UI.hbox(spacing: 8, children))
    }

    private func passphraseRows(for source: Address) -> [Widget] {
        guard let wallet = dapps.wallet(for: source), wallet.keyKind == .encrypted else { return [] }
        adw_preferences_row_set_title(passphraseField.as(), "Password for “\(wallet.alias)”")
        return [passphraseField]
    }

    private var needsPassphrase: Bool {
        switch request {
        case .operation(_, _, _, _, let source, _), .signPayload(_, _, let source, _, _):
            return dapps.wallet(for: source)?.keyKind == .encrypted
        default:
            return false
        }
    }

    private func updateButtons() {
        setBusy(isWorking ? workingText : nil)
        if dapps.undelivered[request.id] != nil {
            let dismissButton = button("Dismiss", role: .cancel) { [unowned self] in Task { await self.dapps.reject(self.request) } }
            dismissButton.isSensitive = !isWorking
            let again = button("Send reply again", role: .prominent, isDefault: true) { [unowned self] in
                self.isWorking = true
                self.updateButtons()
                Task { defer { self.isWorking = false; self.updateButtons() }; await self.dapps.resendReply(self.request) }
            }
            again.isSensitive = !isWorking
            setButtons([dismissButton, again])
        } else {
            let reject = button("Reject", role: .cancel) { [unowned self] in Task { await self.dapps.reject(self.request) } }
            reject.isSensitive = !isWorking
            approveButton.isSensitive = !(isWorking || (request.isPermission && chosenWallet == nil) || (needsPassphrase && Form.text(passphraseField).isEmpty)
                                          || (request.isOperation && prepared?.requestID != request.id))
            setButtons([reject, approveButton])
        }
    }

    private var approveTitle: String {
        switch request {
        case .permission: "Connect"
        case .operation: "Approve and Send"
        case .signPayload: "Sign"
        case .unsupported: "Dismiss"
        }
    }

    private var workingText: String {
        if let hash = dapps.awaitingHash { return "Waiting for the previous operation \(hash.prefix(10))… to reach a block…" }
        let onLedger = sourceWallet?.keyKind == .ledger
        switch request {
        case .operation: return onLedger ? "Confirm on your Ledger…" : "Signing and sending…"
        case .signPayload: return onLedger ? "Sign on your Ledger…" : "Signing…"
        default: return "Working…"
        }
    }

    private var sourceWallet: Wallet? {
        switch request {
        case .operation(_, _, _, _, let source, _), .signPayload(_, _, let source, _, _): dapps.wallet(for: source)
        default: nil
        }
    }

    private func approve() {
        isWorking = true
        updateButtons()
        let passphrase = needsPassphrase ? Form.text(passphraseField) : nil
        Task {
            defer { isWorking = false; updateButtons() }
            switch request {
            case .permission:
                if let chosenWallet { await dapps.approvePermission(request, with: chosenWallet) }
            case .operation:
                guard let prepared, prepared.requestID == request.id else { return }
                await dapps.approveOperation(request, prepared: prepared, passphrase: passphrase)
            case .signPayload:
                await dapps.approveSignature(request, passphrase: passphrase)
            case .unsupported:
                await dapps.reject(request)
            }
        }
    }

    private func scopeName(_ scope: String) -> String {
        switch scope {
        case "sign": "sign messages"
        case "operation_request": "request operations"
        default: scope
        }
    }

    /// Micheline string payloads (0x0501 + length + UTF-8) are shown as text; anything else as hex.
    private func decodedPayload(_ payload: String, signingType: String) -> String {
        if signingType == "micheline", payload.hasPrefix("0501"), payload.count > 12,
           let bytes = Hex.bytes(fromHex: String(payload.dropFirst(12))),
           let text = String(bytes: bytes, encoding: .utf8) {
            return text
        }
        return payload
    }

    override func closed() {
        prepareTask?.cancel()
        Form.clear(passphraseField)
    }
}
