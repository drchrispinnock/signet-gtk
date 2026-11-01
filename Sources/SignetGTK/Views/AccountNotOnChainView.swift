import CAdwaita
import Foundation

/// Shown where the balance would be when the node has never seen the address, with the way to
/// fix it: buy tez on mainnet, or use the faucet on a testnet. The GTK counterpart of upstream's
/// `Views/AccountNotOnChainView.swift`.
@MainActor
final class AccountNotOnChainView {
    let model: WalletViewModel
    let wallet: Wallet
    let root: Widget
    private let explanationLabel = UI.label(classes: ["dim-label"], wrap: true)
    private let buttons = UI.hbox(spacing: 8)
    private var copied = false
    private var tracker: Tracker?

    private var network: Network { model.network }

    init(model: WalletViewModel, wallet: Wallet) {
        self.model = model
        self.wallet = wallet
        let circle = UI.circle(UI.image(icon: "dialog-warning-symbolic", pixelSize: 20), size: 44, classes: "warning-circle")
        let text = UI.vbox(spacing: 2, [UI.label("Key not found on chain", classes: ["title-3"]), explanationLabel]).expand(h: true)
        buttons.margins(start: 60)
        root = UI.vbox(spacing: 12, [UI.hbox(spacing: 16, [circle, text]), buttons])
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        UI.setText(explanationLabel, explanation)
        var row: [Widget] = []
        let model = model
        if wallet.address.isContract {
            row.append(copyButton())
        } else if network.faucetURL != nil {
            row.append(UI.button("Get test tez…", classes: ["suggested-action"]) { model.isPresentingFaucet = true })
            row.append(copyButton())
        } else {
            row.append(UI.button("Show address to receive tez…", classes: ["suggested-action"]) { model.isPresentingReceive = true })
            row.append(UI.button("Buy tez…") { model.isPresentingBuy = true }
                .tooltip("Buy tez through \(BuyProvider.choices), delivered to this address"))
        }
        buttons.setChildren(row)
    }

    private var explanation: String {
        if wallet.address.isContract {
            return "No contract with this address exists on \(network.name)."
        }
        if network.faucetURL != nil {
            return "This address has never received tez on \(network.name). Signet can ask the \(network.name) faucet for free test tez."
        }
        return "This address has never received tez on \(network.name). Buy some tez on an exchange and send it here, or have someone send you some."
    }

    private func copyButton() -> Widget {
        let icon = UI.image(icon: copied ? "object-select-symbolic" : "edit-copy-symbolic")
        let label = UI.label(copied ? "Address copied" : "Copy address")
        let button = UI.button(content: UI.hbox(spacing: 6, [icon, label])) {}
        Signals.connect(button, "clicked") { [weak self] in self?.copyAddress(from: button) }
        return button
    }

    private func copyAddress(from button: Widget) {
        UI.copyToClipboard(wallet.address.value, from: button)
        copied = true
        update()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copied = false
            self?.update()
        }
    }
}
