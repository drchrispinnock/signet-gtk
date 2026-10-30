import CAdwaita
import Foundation

/// Key balances: tez first, Etherlink second, then any other tokens. The GTK counterpart of
/// upstream's `Views/AssetListView.swift`.
@MainActor
final class AssetListView {
    let model: WalletViewModel
    let root = UI.vbox(spacing: 12)
    /// Which rows show their breakdown (`@State isExpanded` per row upstream), kept across the
    /// rebuilds a refresh causes.
    private var expanded: Set<AssetBalance.ID> = []
    private var shown: [AssetBalance] = []
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        let assets = model.assets
        guard assets != shown else { return }
        shown = assets
        root.setChildren(assets.map { row(for: $0) })
    }

    /// One balance. Rows with a breakdown get a chevron that expands the detail lines beneath.
    private func row(for asset: AssetBalance) -> Widget {
        var line = [icon(for: asset)]
        if let unavailable = asset.unavailable {
            line.append(UI.label("—", classes: ["title-3", "numeric", "dim-label"]).tooltip(unavailable))
            let reason = UI.label(unavailable, classes: ["dim-label"], wrap: true)
            gtk_label_set_lines(reason.opaque, 2)
            gtk_label_set_ellipsize(reason.opaque, PANGO_ELLIPSIZE_END)
            line.append(reason)
        } else {
            line.append(UI.label(asset.formattedAmount, classes: ["title-3", "numeric"]).align(v: GTK_ALIGN_CENTER))
        }
        line.append(UI.hspacer())
        let top = UI.hbox(spacing: 16, line)
        let column = UI.vbox(spacing: 8, [top])
        column.accessibleLabel("\(asset.name) balance \(asset.formattedAmount)")
        guard !asset.details.isEmpty else { return column }

        let details = UI.vbox(spacing: 6, asset.details.map { detail in
            UI.hbox(spacing: 8, [
                UI.label(detail.label, classes: ["dim-label"]).expand(h: true),
                UI.label(AssetBalance.format(detail.amount, symbol: asset.symbol), classes: ["numeric"]),
            ])
        }).margins(start: 60, end: 24).classes("asset-details")
        let revealer = Widget(gtk_revealer_new()!)
        gtk_revealer_set_transition_type(revealer.opaque, GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        gtk_revealer_set_transition_duration(revealer.opaque, 150)
        gtk_revealer_set_child(revealer.opaque, details.pointer)
        column.append(revealer)

        let chevron = UI.image(icon: "pan-down-symbolic", pixelSize: 16).classes("dim-label")
        let toggle = UI.button(content: chevron, classes: ["flat", "circular"]) {}
        toggle.align(v: GTK_ALIGN_CENTER)
        top.append(toggle)

        let id = asset.id
        let show: @MainActor (Bool) -> Void = { [weak self] open in
            gtk_revealer_set_reveal_child(revealer.opaque, open ? 1 : 0)
            gtk_image_set_from_icon_name(chevron.opaque, open ? "pan-up-symbolic" : "pan-down-symbolic")
            let help = open ? "Hide breakdown" : "Show breakdown"
            toggle.tooltip(help).accessibleLabel(help)
            if open { self?.expanded.insert(id) } else { self?.expanded.remove(id) }
        }
        let flip: @MainActor () -> Void = { show(gtk_revealer_get_reveal_child(revealer.opaque) == 0) }
        Signals.connect(toggle, "clicked", flip)
        // The whole line toggles too (`.onTapGesture` upstream).
        UI.onClick(top, flip)
        show(expanded.contains(id))
        return column
    }

    private func icon(for asset: AssetBalance) -> Widget {
        switch asset.kind {
        case .tez:
            return UI.resourceImage("tezos-token-round", "svg", pixelSize: 44) ?? badge("XTZ")
        case .etherlink:
            return UI.resourceImage("etherlink-avatar", "svg", pixelSize: 44) ?? badge("ETL")
        case .shielded:
            return UI.resourceImage("shield", "png", pixelSize: 44) ?? badge("ZK")
        case .token:
            return badge(String(asset.symbol.prefix(4)))
        }
    }

    private func badge(_ text: String) -> Widget {
        UI.circle(UI.label(text, classes: ["caption-heading"], xalign: 0.5), size: 44, classes: "token-badge")
    }
}
