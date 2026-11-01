import CAdwaita
import Foundation

/// Send tez: compose (recipient + amount), confirm (you → them), then the result. The GTK
/// counterpart of upstream's `Views/SendSheet.swift`, Tezos side only: the `ChainSidePicker`
/// that sends on Etherlink instead is not ported.
@MainActor
final class SendSheet: Sheet {
    /// Everything a side needs, captured together when the sheet opened (S16, S31): the network
    /// shown and linked to is the one the chain service talks to, whatever Settings does later,
    /// and neither side ever borrows the other's service.
    struct SideContext {
        let network: Network
        let chain: any ChainService
        let spendable: Decimal?
        let implicitAccountsOnly: Bool
    }

    private let sender: Wallet
    private let layer1: SideContext
    private let send: SendViewModel
    private var network: Network { layer1.network }
    /// Which step's widgets are on screen, so they are rebuilt only when the step changes.
    private var shownStep: ShownStep?
    private var compose: ComposeTransferView?
    private var confirm: ConfirmTransferView?
    private var result: TransferResultView?

    private enum ShownStep { case compose, confirm, result }

    init(model: WalletViewModel, sender: Wallet) {
        self.sender = sender
        (layer1, _) = Self.capture(model)
        send = Self.makeSend(model: model, sender: sender, wallets: model.wallets, context: layer1)
        super.init(model: model, width: 520)
        trackers.append(Tracker { [unowned self] in self.showStep() })
        // `.task(id: side)`.
        Task { await send.recoverPending() }
    }

    /// Both sides as they are now; the Etherlink side exists only when its network and service
    /// are both there, and the pair never changes afterwards.
    static func capture(_ model: WalletViewModel) -> (layer1: SideContext, layer2: SideContext?) {
        let layer1 = SideContext(network: model.network, chain: model.chainService, spendable: model.tezBalance?.spendable, implicitAccountsOnly: false)
        guard let network = model.network.layer2, let chain = model.layer2Chain else { return (layer1, nil) }
        return (layer1, SideContext(network: network, chain: chain, spendable: model.etherlinkSpendable, implicitAccountsOnly: true))
    }

    private static func makeSend(model: WalletViewModel, sender: Wallet, wallets: [Wallet], context: SideContext) -> SendViewModel {
        SendViewModel(
            sender: sender,
            wallets: wallets,
            chain: context.chain,
            spendable: context.spendable,
            implicitAccountsOnly: context.implicitAccountsOnly,
            // SendViewModel (main actor) is the only caller.
            signerProvider: { [model] wallet, passphrase in try MainActor.assumeIsolated { try model.signingKey(for: wallet, passphrase: passphrase) } },
            proofProvider: { [model] wallet, passphrase in try await model.proofOfPossession(for: wallet, passphrase: passphrase) }
        )
    }

    private func showStep() {
        let step: ShownStep = switch send.step {
        case .compose: .compose
        case .confirm, .sending: .confirm
        case .sent, .unknown, .confirmed: .result
        }
        guard step != shownStep else { return }
        shownStep = step
        compose = nil
        confirm = nil
        result = nil
        setError(nil)
        setBusy(nil)
        switch step {
        case .compose: compose = ComposeTransferView(sheet: self, send: send, network: network)
        case .confirm: confirm = ConfirmTransferView(sheet: self, send: send, network: network)
        case .result:
            result = TransferResultView(sheet: self, send: send, network: network) { [weak self] in
                guard let self else { return }
                self.dismiss()
                Task { [model] in await model.refreshAfterOperation() }
            }
        }
    }

    override func closed() { send.passphrase = "" }
}

// MARK: - Step 1

@MainActor
private final class ComposeTransferView {
    private unowned let sheet: SendSheet
    private let send: SendViewModel
    private let network: Network
    private let recipientField: Widget
    private let recipientStatus = UI.hbox(spacing: 8)
    private let suggestions = UI.vbox(spacing: 0)
    private let amountField: Widget
    private let maxButton: Widget
    private let passphraseRow: Widget
    private let passphraseField: Widget
    private var continueButton: Widget!
    private var shownSuggestions: [Wallet] = []
    private var tracker: Tracker?

    init(sheet: SendSheet, send: SendViewModel, network: Network) {
        self.sheet = sheet
        self.send = send
        self.network = network
        let proceed: @MainActor () -> Void = { [send] in if send.canProceed { Task { await send.proceedToConfirm() } } }

        var from = [AccountAvatarView(address: send.sender.address, size: 24).root, UI.label(send.sender.alias),
                    UI.label(send.sender.address.shortened(), classes: ["address", "dim-label"])]
        if let spendable = send.spendable {
            from.append(UI.label("\(AssetBalance.format(spendable, symbol: "tz")) spendable", classes: ["dim-label"]))
        }
        let fromRow = Form.labeled("From", content: UI.hbox(spacing: 8, from))

        recipientField = Form.entry(send.implicitAccountsOnly ? "To (tz1, tz2 or tz3 address, name.tez, or an account from your list)"
                                                               : "To (address, name.tez, or an account from your list)",
                                    text: send.recipientText, monospaced: true,
                                    onChange: nil, onSubmit: proceed)
        let recipientBox = UI.vbox(spacing: 6, [recipientStatus, suggestions])
        let recipientRow = Form.row(recipientBox)

        amountField = Form.entry("Amount (tz)", text: send.amountText, monospaced: true, onSubmit: proceed)
        passphraseField = PasswordEntry.make(placeholder: "Password for “\(send.sender.alias)”",
                                             onChange: { [send] in send.passphrase = $0 }, onSubmit: proceed)
        maxButton = UI.button("Max", classes: ["flat"]) { [send] in send.useMaximum() }
        maxButton.tooltip("Everything except a small reserve for the fee")
        Form.addSuffix(maxButton, to: amountField)

        passphraseRow = UI.hbox(spacing: 8, [UI.image(icon: "system-lock-screen-symbolic").classes("dim-label"), passphraseField.expand(h: true)])
        gtk_editable_set_text(passphraseField.opaque, send.passphrase)

        Signals.connect(recipientField, "changed") { [unowned self] in self.send.recipientText = Form.text(self.recipientField) }
        Signals.connect(amountField, "changed") { [unowned self] in self.send.amountText = Form.text(self.amountField) }

        sheet.content.setChildren([
            Sheet.title("Send tez"),
            Form.group([fromRow, recipientField, recipientRow, amountField]),
            passphraseRow,
        ])
        continueButton = sheet.button("Continue", role: .prominent, isDefault: true) { [send] in Task { await send.proceedToConfirm() } }
        sheet.setButtons([sheet.cancelButton(), continueButton])
        sheet.focus(recipientField)
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        Form.setText(amountField, send.amountText)
        maxButton.isSensitive = send.spendable != nil
        passphraseRow.isVisible = send.needsPassphraseForProof
        sheet.setError(send.errorMessage)
        continueButton.isSensitive = send.canProceed
        updateRecipientStatus()
        updateSuggestions()
    }

    private func updateRecipientStatus() {
        if let recipient = send.recipient {
            var children = [AccountAvatarView(address: recipient.address, size: 20).root, UI.label(recipient.displayName), VerificationTag.make(recipient)]
            if recipient.wallet == nil, let domain = recipient.domains.first, domain != recipient.displayName {
                children.append(UI.label(domain, classes: ["dim-label"]))
            }
            recipientStatus.setChildren(children)
        } else if send.isResolving {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            recipientStatus.setChildren([spinner, UI.label("Looking up name…", classes: ["dim-label"])])
        } else if !send.recipientText.isEmpty, send.suggestions.isEmpty, send.errorMessage == nil {
            recipientStatus.setChildren([UI.image(icon: "dialog-warning-symbolic").classes("dim-label"), UI.label("Not a valid address or .tez name", classes: ["dim-label"])])
        } else {
            recipientStatus.setChildren([])
        }
        recipientStatus.isVisible = gtk_widget_get_first_child(recipientStatus.pointer) != nil
    }

    private func updateSuggestions() {
        let list = send.recipient == nil ? Array(send.suggestions.prefix(6)) : []
        suggestions.isVisible = !list.isEmpty
        gtk_widget_set_visible(gtk_widget_get_parent(gtk_widget_get_parent(suggestions.pointer)), recipientStatus.isVisible || !list.isEmpty ? 1 : 0)
        guard list != shownSuggestions else { return }
        shownSuggestions = list
        suggestions.setChildren(list.map { wallet in
            let row = UI.hbox(spacing: 8, [
                AccountAvatarView(address: wallet.address, size: 20).root, UI.label(wallet.alias),
                UI.label(wallet.address.shortened(), classes: ["address", "dim-label"]), UI.hspacer(),
                UI.label(wallet.keyKind == KeyKind.none ? "Address book" : "My account", classes: ["dim-label", "caption"]),
            ])
            return UI.button(content: row, classes: ["flat", "suggestion"]) { [send] in send.choose(wallet) }
        })
    }
}

/// "Verified" when the recipient is one of ours; otherwise the name is hearsay from an indexer.
@MainActor
enum VerificationTag {
    static func make(_ recipient: SendViewModel.Recipient) -> Widget {
        if recipient.isVerified {
            let text = recipient.wallet?.keyKind == KeyKind.none ? "Address book" : "My account"
            return UI.hbox(spacing: 3, [UI.image(icon: "object-select-symbolic", pixelSize: 10), UI.label(text)]).classes("tag", "verified-tag").align(v: GTK_ALIGN_CENTER)
        }
        return UI.hbox(spacing: 3, [UI.image(icon: "dialog-question-symbolic", pixelSize: 10), UI.label("Not verified")]).classes("tag", "unverified-tag").align(v: GTK_ALIGN_CENTER)
            .tooltip("This name comes from the recipient's public profile (TzProfiles via TzKT), not from your own records. Check the address.")
    }
}

/// A password field outside a form (`SecureField(…).textFieldStyle(.roundedBorder)`).
@MainActor
enum PasswordEntry {
    static func make(placeholder: String, onChange: @escaping @MainActor (String) -> Void, onSubmit: (@MainActor () -> Void)? = nil) -> Widget {
        let entry = Widget(gtk_password_entry_new()!)
        gtk_password_entry_set_show_peek_icon(entry.opaque, 1)
        setPlaceholder(entry, placeholder)
        entry.accessibleLabel(placeholder)
        Signals.connect(entry, "changed") { onChange(String(cString: gtk_editable_get_text(entry.opaque))) }
        if let onSubmit { Signals.connect(entry, "activate", onSubmit) }
        return entry
    }

    /// `GtkPasswordEntry`'s `placeholder-text` property, which has no setter function.
    static func setPlaceholder(_ entry: Widget, _ text: String) {
        var value = GValue()
        g_value_init(&value, gType(16))   // G_TYPE_STRING
        g_value_set_string(&value, text)
        g_object_set_property(UnsafeMutablePointer(OpaquePointer(entry.pointer)), "placeholder-text", &value)
        g_value_unset(&value)
    }

    static func text(_ entry: Widget) -> String { String(cString: gtk_editable_get_text(entry.opaque)) }
}

// MARK: - Step 2

@MainActor
private final class ConfirmTransferView {
    private unowned let sheet: SendSheet
    private let send: SendViewModel
    private let network: Network
    private var passphraseRow: Widget?
    private var sendButton: Widget!
    private var backButton: Widget!
    private var tracker: Tracker?

    init(sheet: SendSheet, send: SendViewModel, network: Network) {
        self.sheet = sheet
        self.send = send
        self.network = network
        var children = [Sheet.title("Confirm")]

        if let recipient = send.recipient, let amount = send.amount {
            let arrow = UI.vbox(spacing: 4, [
                UI.image(icon: "go-next-symbolic", pixelSize: 28).classes("tezos-blue"),
                UI.label(AssetBalance.format(amount, symbol: "tz"), classes: ["heading", "numeric"], xalign: 0.5),
            ]).expand(h: true).margins(top: 28)
            children.append(UI.hbox(spacing: 0, [
                party(address: send.sender.address, name: send.sender.alias, subtitle: send.sender.address.shortened(), tag: nil),
                arrow,
                party(address: recipient.address, name: recipient.displayName,
                      subtitle: recipient.domains.first.flatMap { $0 == recipient.displayName ? nil : $0 } ?? recipient.address.shortened(),
                      tag: VerificationTag.make(recipient)),
            ]).margins(top: 8, bottom: 8))

            var rows = [Form.labeled("To", value: recipient.address.value, monospaced: true).row]
            if let estimate = send.estimate {
                rows.append(Form.labeled("Amount", value: AssetBalance.format(amount, symbol: "tz")).row)
                rows.append(Form.labeled("Fee", value: AssetBalance.format(estimate.fee, symbol: "tz")).row)
                if estimate.burn > 0 {
                    let note = UI.label("The recipient has never held tez; the chain charges once to create the account.", classes: ["dim-label", "caption"], wrap: true, xalign: 1)
                    gtk_label_set_max_width_chars(note.opaque, 40)
                    rows.append(Form.labeled("Allocation", content: UI.vbox(spacing: 2, [
                        UI.label(AssetBalance.format(estimate.burn, symbol: "tz"), xalign: 1), note,
                    ])))
                }
                let total = Form.labeled("Total", value: AssetBalance.format(estimate.total, symbol: "tz"))
                total.value.classes("heading")
                rows.append(total.row)
            }
            children.append(Form.group(rows))
        }

        if send.needsPassphrase {
            let field = PasswordEntry.make(placeholder: "Password for “\(send.sender.alias)”",
                                           onChange: { [send] in send.passphrase = $0 },
                                           onSubmit: { [send] in if !send.passphrase.isEmpty { Task { await send.send() } } })
            gtk_editable_set_text(field.opaque, send.passphrase)
            let row = UI.hbox(spacing: 8, [UI.image(icon: "system-lock-screen-symbolic").classes("dim-label"), field.expand(h: true)])
            passphraseRow = row
            children.append(row)
            sheet.focus(field)
        }
        sheet.content.setChildren(children)

        backButton = sheet.button("Back") { [send] in send.backToCompose() }
        sendButton = sheet.button("Confirm and Send", role: .prominent, isDefault: true) { [send] in Task { await send.send() } }
        sheet.setButtons([backButton, sendButton])
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        let sending = send.step == .sending
        sheet.setError(send.errorMessage)
        backButton.isSensitive = !sending
        sendButton.isSensitive = !(sending || send.isBusy || (send.needsPassphrase && send.passphrase.isEmpty))
        sheet.canClose = !sending
        passphraseRow?.isSensitive = !sending
        if sending {
            sheet.setBusy(send.signsOnLedger ? "Confirm on your Ledger…" : "Signing and sending…")
        } else {
            sheet.setBusy(nil)
        }
    }

    private func party(address: Address, name: String, subtitle: String, tag: Widget?) -> Widget {
        let nameLabel = UI.label(name, classes: ["heading"], xalign: 0.5)
        let subtitleLabel = UI.label(subtitle, classes: ["address", "dim-label"], xalign: 0.5)
        for label in [nameLabel, subtitleLabel] { gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_END) }
        var column = [AccountAvatarView(address: address, size: 72).root.align(h: GTK_ALIGN_CENTER), nameLabel, subtitleLabel]
        if let tag { column.append(tag.align(h: GTK_ALIGN_CENTER)) }
        return UI.vbox(spacing: 6, column).size(width: 150)
    }
}

// MARK: - Step 3

@MainActor
private final class TransferResultView {
    private unowned let sheet: Sheet
    private let send: SendViewModel
    private let network: Network
    private let onDone: @MainActor () -> Void
    private var shown: SendViewModel.Step?
    private var tracker: Tracker?

    init(sheet: Sheet, send: SendViewModel, network: Network, onDone: @escaping @MainActor () -> Void) {
        self.sheet = sheet
        self.send = send
        self.network = network
        self.onDone = onDone
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        sheet.setError(send.errorMessage)
        let busy = send.isBusy
        var children: [Widget] = []
        switch send.step {
        case .sent(let hash):
            children.append(ResultHeader.make(icon: "mail-send-symbolic", title: "Sent", subtitle: "Waiting for the next block…", spinning: true))
            children.append(OperationLink.make(hash, network: network))
        case .confirmed(let hash, let level):
            children.append(ResultHeader.make(icon: "object-select-symbolic", title: "Confirmed", subtitle: "Included in block \(level.formatted())", spinning: false))
            children.append(OperationLink.make(hash, network: network))
        case .unknown(let hash):
            children.append(ResultHeader.make(icon: "dialog-question-symbolic", title: "Not confirmed by the node", subtitle: busy ? "Watching the chain…" : "The node's answer was lost", spinning: busy))
            children.append(OperationLink.make(hash, network: network))
            children.append(UI.label("The operation was signed and handed to the node, but its answer did not arrive. Signet is watching the chain for it. Sending again sends the same signed operation, so it cannot be paid twice.",
                                     classes: ["dim-label"], wrap: true))
        default:
            break
        }
        if let address = send.sent?.originatedAddress {
            children.append(Form.group([Form.labeled("Contract address", value: address, monospaced: true).row]))
        }
        sheet.content.setChildren(children)

        var buttons: [Widget] = []
        if case .unknown = send.step {
            let again = sheet.button("Send the same operation again") { [send] in Task { await send.rebroadcast() } }
            again.isSensitive = !busy
            buttons.append(again)
        }
        buttons.append(sheet.button("Done", role: .prominent, isDefault: true, action: onDone))
        sheet.setButtons(buttons)
    }
}

/// The big icon, title and line of status at the top of a result step.
@MainActor
enum ResultHeader {
    static func make(icon: String, title: String, subtitle: String, spinning: Bool) -> Widget {
        let image = UI.image(icon: icon, pixelSize: 36).classes(spinning ? "tezos-blue" : "success-icon")
        var line: [Widget] = []
        if spinning {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            line.append(spinner)
        }
        line.append(UI.label(subtitle, classes: ["dim-label"]))
        return UI.hbox(spacing: 12, [image, UI.vbox(spacing: 2, [Sheet.title(title), UI.hbox(spacing: 6, line)]).align(v: GTK_ALIGN_CENTER)])
    }
}

/// An operation hash and a link to it in the explorer.
@MainActor
enum OperationLink {
    static func make(_ hash: String, network: Network) -> Widget {
        let label = UI.label(hash, classes: ["address"])
        gtk_label_set_selectable(label.opaque, 1)
        gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_MIDDLE)
        var children = [label.expand(h: true)]
        if let url = network.explorerURL(operation: hash) {
            children.append(Widget(gtk_link_button_new_with_label(url.absoluteString, "View in explorer")!))
        }
        return UI.hbox(spacing: 8, children)
    }
}
