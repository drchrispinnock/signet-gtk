import Foundation

/// Send tez: compose (recipient + amount), confirm (you → them), then the result. The GTK
/// counterpart of upstream's `Views/SendSheet.swift`; only the side capture is here so far.
@MainActor
struct SendSheet {
    /// Everything a side needs, captured together when the sheet opened (S16, S31): the network
    /// shown and linked to is the one the chain service talks to, whatever Settings does later,
    /// and neither side ever borrows the other's service.
    struct SideContext {
        let network: Network
        let chain: any ChainService
        let spendable: Decimal?
        let implicitAccountsOnly: Bool
    }

    /// Both sides as they are now; the Etherlink side exists only when its network and service
    /// are both there, and the pair never changes afterwards.
    static func capture(_ model: WalletViewModel) -> (layer1: SideContext, layer2: SideContext?) {
        let layer1 = SideContext(network: model.network, chain: model.chainService, spendable: model.tezBalance?.spendable, implicitAccountsOnly: false)
        guard let network = model.network.layer2, let chain = model.layer2Chain else { return (layer1, nil) }
        return (layer1, SideContext(network: network, chain: chain, spendable: model.etherlinkSpendable, implicitAccountsOnly: true))
    }
}
