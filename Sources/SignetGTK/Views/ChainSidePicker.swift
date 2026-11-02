import CAdwaita
import Foundation

/// Which side of the bridge a sheet is about: the account on Tezos, or the same account on Etherlink.
enum ChainSide: String, CaseIterable, Identifiable {
    case tezos = "Tezos", etherlink = "Etherlink"
    var id: String { rawValue }
    /// The logo shipped as a resource (upstream's asset names `TezosToken` and `EtherlinkLogo`).
    var logo: (name: String, ext: String) { self == .tezos ? ("tezos-token-round", "svg") : ("etherlink-avatar", "svg") }
}

/// The chain's logo and, when `canSwitch`, a drop-down beside it to switch between Tezos and
/// Etherlink. Used at the top left of the Receive and Send sheets. The GTK counterpart of
/// upstream's `Views/ChainSidePicker.swift`.
@MainActor
final class ChainSidePicker {
    let root = UI.hbox(spacing: 6)
    private let logo = UI.hbox(spacing: 0)
    private let dropDown: Widget
    private(set) var side: ChainSide
    private let onChange: @MainActor (ChainSide) -> Void

    init(side: ChainSide = .tezos, canSwitch: Bool, onChange: @escaping @MainActor (ChainSide) -> Void) {
        self.side = side
        self.onChange = onChange
        var names = ChainSide.allCases.map { strdup($0.rawValue) }
        names.append(nil)
        let made = names.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { gtk_drop_down_new_from_strings($0)! }
        }
        for name in names { free(name) }
        dropDown = Widget(made)
        gtk_drop_down_set_selected(dropDown.opaque, guint(ChainSide.allCases.firstIndex(of: side) ?? 0))
        dropDown.align(v: GTK_ALIGN_CENTER).isVisible = canSwitch
        root.setChildren([logo, dropDown])
        showLogo()
        Signals.connect(dropDown, "notify::selected") { [unowned self] in
            let index = Int(gtk_drop_down_get_selected(self.dropDown.opaque))
            guard ChainSide.allCases.indices.contains(index), ChainSide.allCases[index] != self.side else { return }
            self.side = ChainSide.allCases[index]
            self.showLogo()
            self.onChange(self.side)
        }
        root.retain(self, key: "signet-chain-side")
    }

    private func showLogo() {
        logo.setChildren([Self.logo(side, size: 22)])
        dropDown.tooltip("On \(side.rawValue). Switch between Tezos and Etherlink.")
    }

    static func logo(_ side: ChainSide, size: Int32) -> Widget {
        UI.resourceImage(side.logo.name, side.logo.ext, pixelSize: size) ?? UI.label(side.rawValue, classes: ["caption"])
    }
}
