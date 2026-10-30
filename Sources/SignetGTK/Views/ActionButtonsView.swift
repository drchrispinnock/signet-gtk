import CAdwaita
import Foundation

/// Send, Receive, Buy (Get on testnets), Stake. Selling is out of scope: it would mean handling bank
/// accounts. Buttons whose flow does not exist yet are disabled. The GTK counterpart of upstream's
/// `Views/ActionButtonsView.swift`.
@MainActor
final class ActionButtonsView {
    let model: WalletViewModel
    let root: Widget
    private let row = UI.hbox(spacing: 12)
    private let reason = UI.label(classes: ["dim-label", "caption"], wrap: true)
    private let reasonRow: Widget
    private var tracker: Tracker?

    private struct Action {
        let title: String
        let symbol: String
        let enabled: Bool
        let perform: @MainActor () -> Void
    }

    init(model: WalletViewModel) {
        self.model = model
        gtk_box_set_homogeneous(row.as(), 1)
        reasonRow = UI.hbox(spacing: 6, [UI.image(icon: "help-about-symbolic", pixelSize: 12).classes("dim-label"), reason.expand(h: true)])
        root = UI.vbox(spacing: 8, [row, reasonRow])
        tracker = Tracker { [unowned self] in self.update() }
    }

    /// Address-book entries have no key, so none of the actions apply to them.
    private var isWatchOnly: Bool { model.selectedWallet?.keyKind == KeyKind.none }
    /// Faucets only fund implicit accounts; a contract (KT1) is funded by sending to it.
    private var isContract: Bool { model.selectedWallet?.address.isContract == true }
    /// Keys on disk (clear or encrypted) and on a Ledger can sign; remote signers cannot yet.
    private var canSign: Bool { model.selectedWallet?.keyKind.canSign == true }

    private var actions: [Action] {
        let model = model
        return [
            Action(title: "Send", symbol: "go-up-symbolic", enabled: canSign && !model.accountNotOnChain) { model.isPresentingSend = true },
            Action(title: "Receive", symbol: "go-down-symbolic", enabled: model.selectedWallet != nil && !isWatchOnly) { model.isPresentingReceive = true },
            model.network.faucetURL != nil
                ? Action(title: "Get", symbol: "weather-showers-symbolic", enabled: model.selectedWallet != nil && !isContract) { model.isPresentingFaucet = true }
                : Action(title: "Buy", symbol: "list-add-symbolic", enabled: model.selectedWallet != nil && model.network.isMainnet) { model.isPresentingBuy = true },
            Action(title: "Stake", symbol: "power-profile-performance-symbolic", enabled: canSign && !model.accountNotOnChain) { model.isPresentingStaking = true },
        ]
    }

    private func helpText(for action: Action) -> String {
        if action.enabled { return action.title == "Buy" ? "Buy tez through \(BuyProvider.choices)" : action.title }
        if action.title == "Buy", !model.network.isMainnet { return "Buying is only possible on Mainnet" }
        if action.title == "Get", isContract { return "The faucet cannot fund a contract; send it tez from an account" }
        if isWatchOnly { return "Not available for a watch-only address" }
        if action.title == "Send" {
            if model.accountNotOnChain { return "This address has no tez on this network" }
            if let kind = model.selectedWallet?.keyKind, !kind.canSign { return "Sending with \(kind.rawValue) keys is not supported yet" }
        }
        return "\(action.title) is coming soon"
    }

    /// Why Send is off, spelled out under the row so it is not just a tooltip.
    private var sendUnavailableReason: String? {
        guard let wallet = model.selectedWallet, !(canSign && !model.accountNotOnChain) else { return nil }
        if isWatchOnly { return "This is an address-book entry; Signet holds no key for it, so it cannot send." }
        if model.accountNotOnChain { return "This address has no tez on \(model.network.name), so there is nothing to send." }
        switch wallet.keyKind {
        case .remote: return "This account signs through a remote signer, which Signet does not support yet."
        default: return "Signet cannot sign for this account yet."
        }
    }

    private func update() {
        row.setChildren(actions.map { action in
            let content = UI.vbox(spacing: 6, [UI.image(icon: action.symbol, pixelSize: 20), UI.label(action.title, xalign: 0.5)])
            let button = UI.button(content: content, classes: ["action-tile"], action: action.perform)
            button.isSensitive = action.enabled
            return button.tooltip(helpText(for: action))
        })
        let reasonText = sendUnavailableReason
        UI.setText(reason, reasonText ?? "")
        reasonRow.isVisible = reasonText != nil
    }
}
