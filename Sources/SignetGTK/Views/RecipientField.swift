import CAdwaita
import Foundation

/// The "To" field of the token and domain transfer sheets, as upstream writes it in each of
/// them: a text field resolved by a `SendViewModel` (addresses, `.tez` names and our own
/// accounts, Etherlink's tz1–tz3 rule), the resolved recipient or why there is none beneath,
/// and up to six suggestions from the account list. Two form rows (`rows`); the sheet reads
/// `recipient.recipient` and calls `render()` from its own tracker.
@MainActor
final class RecipientField {
    let recipient: SendViewModel
    let entry: Widget
    private let status = UI.hbox(spacing: 8)
    private let suggestions = UI.vbox(spacing: 0)
    private let statusRow: Widget
    private var shownSuggestions: [Wallet]?
    var rows: [Widget] { [entry, statusRow] }

    init(model: WalletViewModel, chain: any ChainService, implicitAccountsOnly: Bool) {
        let sender = model.selectedWallet ?? Wallet(alias: "", address: Address(""), keyKind: .none)
        recipient = SendViewModel(sender: sender, wallets: model.wallets, chain: chain, spendable: nil,
                                  implicitAccountsOnly: implicitAccountsOnly, signerProvider: { _, _ in nil })
        entry = Form.entry(implicitAccountsOnly ? "To (tz1, tz2 or tz3 address, name.tez, or an account from your list)"
                                                : "To (address, name.tez, or an account from your list)", monospaced: true)
        statusRow = Form.row(UI.vbox(spacing: 6, [status, suggestions]))
        Signals.connect(entry, "changed") { [unowned self] in self.recipient.recipientText = Form.text(self.entry) }
    }

    /// Reads everything the status shows, so a tracker calling it follows the lookup.
    func render() {
        if let resolved = recipient.recipient {
            var children = [AccountAvatarView(address: resolved.address, size: 20).root, UI.label(resolved.displayName), VerificationTag.make(resolved)]
            if resolved.wallet == nil, let domain = resolved.domains.first, domain != resolved.displayName {
                children.append(UI.label(domain, classes: ["dim-label"]))
            }
            status.setChildren(children)
        } else if recipient.isResolving {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            status.setChildren([spinner, UI.label("Looking up name…", classes: ["dim-label"])])
        } else if let error = recipient.errorMessage {
            status.setChildren([UI.label(error, classes: ["error-text"], wrap: true)])
        } else if !recipient.recipientText.isEmpty, recipient.suggestions.isEmpty {
            status.setChildren([UI.image(icon: "dialog-warning-symbolic").classes("dim-label"), UI.label("Not a valid address or .tez name", classes: ["dim-label"])])
        } else {
            status.setChildren([])
        }
        status.isVisible = gtk_widget_get_first_child(status.pointer) != nil

        let list = recipient.recipient == nil ? Array(recipient.suggestions.prefix(6)) : []
        suggestions.isVisible = !list.isEmpty
        statusRow.isVisible = status.isVisible || !list.isEmpty
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

    var isSensitive: Bool {
        get { entry.isSensitive }
        set { entry.isSensitive = newValue; statusRow.isSensitive = newValue }
    }
}
