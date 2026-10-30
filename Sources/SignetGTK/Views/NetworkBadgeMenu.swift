import CAdwaita
import Foundation

/// The network pill in the header: green on mainnet, orange on a testnet. Click it to switch.
/// The GTK counterpart of upstream's `Views/NetworkBadgeMenu.swift`.
@MainActor
final class NetworkBadgeMenu {
    let root: Widget
    private let name = UI.label()
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        let chevron = UI.image(icon: "pan-down-symbolic", pixelSize: 8)
        root = MenuButtons.make(content: UI.hbox(spacing: 3, [name, chevron]), classes: ["network-badge"])
        tracker = Tracker { [unowned self] in
            let network = model.network
            UI.setText(self.name, network.name)
            self.root.setClass("mainnet", network.isMainnet)
            self.root.setClass("testnet", !network.isMainnet)
            self.root.tooltip("Connected to \(network.rpcURL.absoluteString). Click to switch network.")
            self.root.accessibleLabel("Network \(network.name). Switch network")

            let menu = MenuBuilder()
            menu.section()
            for base in Network.all {
                let resolved = model.resolved(base)
                menu.choice("\(resolved.name)  \(resolved.rpcURL.host() ?? "")", action: Operations.selectNetwork, value: base.name)
            }
            menu.section().item("Networks…", action: "networks")
            MenuButtons.setMenu(self.root, menu)
        }
    }
}
