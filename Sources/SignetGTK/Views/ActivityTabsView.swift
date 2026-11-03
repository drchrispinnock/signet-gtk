import CAdwaita
import Foundation

/// Bottom section of the dashboard: recent transactions or NFTs, chosen with a segmented control.
/// The GTK counterpart of upstream's `Views/ActivityTabsView.swift`. The window's content
/// scrolls as a whole, so the lists here grow rather than scroll on their own.
@MainActor
final class ActivityTabsView {
    let model: WalletViewModel
    let root: Widget
    private let toggles: Widget
    private let layers: LayerToggles
    private let body = UI.vbox(spacing: 0)
    private var shownTab: WalletViewModel.ActivityTab?
    private var transactions: TransactionListView?
    private var tokens: TokenListView?
    private var nfts: NFTGridView?
    private var trackers: [Tracker] = []

    init(model: WalletViewModel) {
        self.model = model
        toggles = Widget(adw_toggle_group_new()!)
        for tab in WalletViewModel.ActivityTab.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, tab.rawValue)
            adw_toggle_set_name(toggle, tab.rawValue)
            adw_toggle_group_add(toggles.opaque, toggle)
        }
        toggles.size(width: 400).align(h: GTK_ALIGN_START)
        gtk_widget_set_hexpand(toggles.pointer, 0)
        Signals.connect(toggles, "notify::active-name") { [model, toggles] in
            guard let name = adw_toggle_group_get_active_name(toggles.opaque),
                  let tab = WalletViewModel.ActivityTab(rawValue: String(cString: name)) else { return }
            if model.activityTab != tab { model.activityTab = tab }
        }
        layers = LayerToggles(model: model)
        root = UI.vbox(spacing: 10, [UI.hbox(spacing: 12, [toggles, UI.hspacer(), layers.root]), body])
        trackers.append(Tracker { [unowned self] in self.update() })
        trackers.append(Tracker { [unowned self] in
            let filters = self.model.filtersLayers
            self.layers.root.isVisible = filters
            // `.frame(maxWidth: 400)`, narrower beside the layer toggles so the row still fits the
            // narrowest window (480 less the margins).
            self.toggles.size(width: filters ? 340 : 400)
        })
    }

    private func update() {
        let tab = model.activityTab
        adw_toggle_group_set_active_name(toggles.opaque, tab.rawValue)
        guard tab != shownTab else { return }
        shownTab = tab
        transactions = nil
        tokens = nil
        nfts = nil
        switch tab {
        case .transactions:
            let view = TransactionListView(model: model)
            transactions = view
            body.setChildren([view.root])
        case .assets:
            let view = TokenListView(model: model)
            tokens = view
            body.setChildren([view.root])
        case .nfts:
            let view = NFTGridView(model: model)
            nfts = view
            body.setChildren([view.root])
        }
    }
}

/// Two logo buttons, Tezos and Etherlink, each lit while that layer's holdings and operations
/// are shown. Beside the activity picker while Layer 2 is on, so every tab can be cut to one chain.
@MainActor
final class LayerToggles {
    let model: WalletViewModel
    let root = UI.hbox(spacing: 4)
    private var buttons: [(layer: Int, name: String, button: Widget, logo: Widget)] = []
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        for (layer, side) in [(1, ChainSide.tezos), (2, ChainSide.etherlink)] {
            let logo = ChainSidePicker.logo(side, size: 16)
            let button = Widget(gtk_toggle_button_new()!)
            gtk_button_set_child(button.as(), logo.pointer)
            button.classes("flat", "layer-toggle").accessibleLabel(side.rawValue).align(v: GTK_ALIGN_CENTER)
            Signals.connect(button, "toggled") { [model] in
                let on = gtk_toggle_button_get_active(button.as()) != 0
                guard on != model.shownLayers.contains(layer) else { return }
                if on { model.shownLayers.insert(layer) } else { model.shownLayers.remove(layer) }
            }
            buttons.append((layer, side.rawValue, button, logo))
            root.append(button)
        }
        root.accessibleLabel("Chains shown")
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        let shown = model.shownLayers
        for (layer, name, button, logo) in buttons {
            let on = shown.contains(layer)
            if (gtk_toggle_button_get_active(button.as()) != 0) != on { gtk_toggle_button_set_active(button.as(), on ? 1 : 0) }
            gtk_widget_set_opacity(logo.pointer, on ? 1 : 0.45)
            button.tooltip(on ? "Showing \(name). Click to hide its transactions, tokens and NFTs." : "Show \(name)")
        }
    }
}

/// A small Etherlink logo beside a layer 2 row's figure or on its tile: the same mark as the
/// dashboard's Etherlink balance row, so a list reads "on Etherlink".
@MainActor
enum EtherlinkMark {
    static func make(size: Int32 = 14) -> Widget {
        let mark = UI.resourceImage("etherlink-avatar", "svg", pixelSize: size) ?? UI.label("ETL", classes: ["caption"])
        return mark.tooltip("On Etherlink")
    }
}

/// The text shown where a list would be: "Loading…", "No transactions yet." and the like.
@MainActor
enum EmptyListText {
    static func make(_ text: String) -> Widget {
        UI.label(text, classes: ["dim-label"], wrap: true, xalign: 0.5).margins(top: 24)
    }
}

/// The last few operations, each with the counterparty's avatar and best-known name.
@MainActor
final class TransactionListView {
    let model: WalletViewModel
    let root = UI.vbox(spacing: 0)
    private var shown: [TezosTransaction]?
    private var shownEmptyText: String?
    private var rows: [TransactionRowView] = []
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        tracker = Tracker { [unowned self] in self.update() }
    }

    private var emptyText: String {
        if model.isLoading { return "Loading…" }
        return model.layerEmptyText(for: "transactions") ?? "No transactions yet."
    }

    private func update() {
        let transactions = model.visibleTransactions
        if transactions.isEmpty {
            let text = emptyText
            guard shown != [] || shownEmptyText != text else { return }
            shown = []
            shownEmptyText = text
            rows = []
            root.setChildren([EmptyListText.make(text)])
            return
        }
        // The rows read names and roles from the model themselves; rebuild only for a new list.
        guard transactions != shown else { return }
        shown = transactions
        shownEmptyText = nil
        rows = transactions.map { TransactionRowView(model: model, transaction: $0) }
        var children: [Widget] = []
        for row in rows {
            children.append(row.root)
            children.append(UI.separator().margins(start: 56))
        }
        root.setChildren(children)
    }
}

@MainActor
final class TransactionRowView {
    let model: WalletViewModel
    let transaction: TezosTransaction
    let root: Widget
    private let headlineLabel = UI.label(classes: ["transaction-headline"])
    private let verified = UI.image(icon: "object-select-symbolic", pixelSize: 12).classes("verified")
    private let subtitleLabel = UI.label(classes: ["dim-label", "caption"])
    private let badge = UI.image(icon: "go-up-symbolic", pixelSize: 9)
    private var tracker: Tracker?

    init(model: WalletViewModel, transaction: TezosTransaction) {
        self.model = model
        self.transaction = transaction

        let avatar: Widget = transaction.counterparty.map { AccountAvatarView(address: $0, size: 40).root }
            ?? UI.vbox().size(width: 40, height: 40).classes("account-avatar")
        let badgeCircle = UI.circle(badge, size: 16, classes: "direction-badge")
        badgeCircle.align(h: GTK_ALIGN_END, v: GTK_ALIGN_END).margins(bottom: -4, end: -4)
        let overlay = Widget(gtk_overlay_new()!)
        gtk_overlay_set_child(overlay.opaque, avatar.pointer)
        gtk_overlay_add_overlay(overlay.opaque, badgeCircle.pointer)
        overlay.align(v: GTK_ALIGN_CENTER)

        for label in [headlineLabel, subtitleLabel] { gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_END) }
        verified.tooltip("One of your accounts or address-book entries")
        var headlineRow = [headlineLabel, verified]
        if !transaction.isApplied { headlineRow.append(UI.label("Failed", classes: ["failed-tag"]).align(v: GTK_ALIGN_CENTER)) }
        let text = UI.vbox(spacing: 2, [UI.hbox(spacing: 6, headlineRow), subtitleLabel]).expand(h: true).align(v: GTK_ALIGN_CENTER)

        var figureRow: [Widget] = []
        if transaction.isLayer2 { figureRow.append(EtherlinkMark.make()) }
        figureRow.append(Self.figure(for: transaction))
        var trailing = [UI.hbox(spacing: 5, figureRow).align(h: GTK_ALIGN_END)]
        if Self.showsDelegatedBalance(transaction) {
            trailing.append(UI.label("delegated balance", classes: ["dim-label", "caption"], xalign: 1))
        }
        if transaction.direction != .incoming, transaction.fee > 0 {
            trailing.append(UI.label("fee \(AssetBalance.format(transaction.fee, symbol: "tz"))", classes: ["dim-label", "caption", "numeric"], xalign: 1))
        }
        let figures = UI.vbox(spacing: 2, trailing).align(v: GTK_ALIGN_CENTER)

        root = UI.hbox(spacing: 12, [overlay, text, figures]).classes("transaction-row")
        UI.onClick(root) { [weak self] in self?.openExplorer() }
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        UI.setText(headlineLabel, headline)
        UI.setText(subtitleLabel, subtitle)
        verified.isVisible = party.isOurs
        let (symbol, colour) = directionBadge
        gtk_image_set_from_icon_name(badge.opaque, symbol)
        if let circle = gtk_widget_get_parent(badge.pointer) {
            for name in ["green", "orange", "blue", "grey"] { gtk_widget_remove_css_class(circle, name) }
            gtk_widget_add_css_class(circle, colour)
        }
        root.tooltip(helpText)
        root.accessibleLabel("\(headline), \(subtitle), \(transaction.amount > 0 ? signedAmount : "")\(transaction.isLayer2 ? ", on Etherlink" : "")")
    }

    // MARK: Pieces

    private static func showsDelegatedBalance(_ transaction: TezosTransaction) -> Bool {
        transaction.amount == 0 && transaction.kind == .delegation && (transaction.delegatedBalance ?? 0) > 0
    }

    /// The amount, the delegator's balance, or the kind of call.
    private static func figure(for transaction: TezosTransaction) -> Widget {
        if transaction.amount > 0 {
            let label = UI.label(signedAmount(transaction), classes: ["numeric", "transaction-amount"], xalign: 1)
            if transaction.direction == .incoming { label.classes("incoming") }
            return label
        }
        if showsDelegatedBalance(transaction), let balance = transaction.delegatedBalance {
            return UI.label(AssetBalance.format(balance, symbol: "tz"), classes: ["numeric", "dim-label"], xalign: 1)
        }
        return UI.label(transaction.kind == .delegation ? "Delegation" : "Call", classes: ["dim-label"], xalign: 1)
    }

    /// The network the row's explorer link belongs to: Etherlink's for a layer 2 row (none if
    /// Layer 2 has since been turned off), else the one in use.
    private var network: Network? { transaction.isLayer2 ? model.network.layer2 : model.network }

    private var party: (name: String, isOurs: Bool) {
        guard let address = transaction.counterparty else { return ("Unknown", false) }
        return model.displayName(for: address, indexerAlias: transaction.counterpartyAlias)
    }

    private var role: TezosTransaction.DelegationRole? {
        model.selectedWallet.flatMap { transaction.delegationRole(for: $0.address) }
    }

    /// The icon on the avatar's corner and the CSS colour class of its circle.
    private var directionBadge: (String, String) {
        switch (role, transaction.direction) {
        case (.delegatorJoined, _): ("list-add-symbolic", "green")
        case (.delegatorLeft, _), (.delegatorMoved, _): ("list-remove-symbolic", "orange")
        case (.weDelegated, _), (.weUndelegated, _): ("avatar-default-symbolic", "blue")
        case (_, .incoming): ("go-down-symbolic", "green")
        case (_, .outgoing): ("go-up-symbolic", "blue")
        case (_, .selfTransfer): ("view-refresh-symbolic", "grey")
        }
    }

    private var headline: String {
        if let role {
            switch role {
            case .weDelegated: return "Delegated to \(party.name)"
            case .weUndelegated: return "Undelegated"
            case .delegatorJoined: return "\(party.name) delegated to you"
            case .delegatorLeft: return "\(party.name) undelegated"
            case .delegatorMoved: return "\(party.name) moved their delegation"
            }
        }
        return switch (transaction.kind, transaction.direction) {
        case (.origination, _): "Originated \(party.name)"
        case (_, .incoming): "From \(party.name)"
        case (_, .selfTransfer): "To yourself"
        case (_, .outgoing): "To \(party.name)"
        }
    }

    private var subtitle: String {
        var parts = [RelativeTime.abbreviated(transaction.timestamp, relativeTo: Date())]
        if let entrypoint = transaction.entrypoint { parts.append("entrypoint \(entrypoint)") }
        else if transaction.isContractCall { parts.append("contract") }
        if let via = transaction.via { parts.append("via \(model.displayName(for: via, indexerAlias: nil).name)") }
        if !party.isOurs, transaction.counterpartyAlias != nil { parts.append("name from TzKT") }
        return parts.joined(separator: " · ")
    }

    private var signedAmount: String { Self.signedAmount(transaction) }

    private static func signedAmount(_ transaction: TezosTransaction) -> String {
        let sign = transaction.direction == .incoming ? "+" : (transaction.direction == .outgoing ? "−" : "")
        return sign + AssetBalance.format(transaction.amount, symbol: "tz")
    }

    private var helpText: String {
        var lines = [transaction.hash, "Block \(transaction.level.formatted())", transaction.timestamp.formatted(date: .abbreviated, time: .shortened)]
        if transaction.isLayer2 { lines.insert("On Etherlink", at: 0) }
        if let address = transaction.counterparty { lines.append(address.value) }
        if network?.explorerURL(operation: transaction.hash) != nil { lines.append("Click to view in the explorer") }
        return lines.joined(separator: "\n")
    }

    private func openExplorer() {
        guard let url = network?.explorerURL(operation: transaction.hash) else { return }
        UI.open(url, from: root)
    }
}

/// `RelativeDateTimeFormatter` with `.abbreviated` units, which swift-corelibs-foundation does
/// not have: "5 min. ago", "3 days ago", in English as the rest of the app is.
enum RelativeTime {
    static func abbreviated(_ date: Date, relativeTo now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        let past = seconds <= 0
        let magnitude = abs(seconds)
        let (count, unit): (Int, String)
        switch magnitude {
        case ..<60: (count, unit) = (magnitude, "sec.")
        case ..<3600: (count, unit) = (magnitude / 60, "min.")
        case ..<86_400: (count, unit) = (magnitude / 3600, "hr.")
        case ..<(7 * 86_400): (count, unit) = (magnitude / 86_400, magnitude / 86_400 == 1 ? "day" : "days")
        case ..<(30 * 86_400): (count, unit) = (magnitude / (7 * 86_400), "wk.")
        case ..<(365 * 86_400): (count, unit) = (magnitude / (30 * 86_400), "mo.")
        default: (count, unit) = (magnitude / (365 * 86_400), "yr.")
        }
        return past ? "\(count) \(unit) ago" : "in \(count) \(unit)"
    }
}

/// The Assets tab: fungible (DeFi) token balances with their logos.
@MainActor
final class TokenListView {
    let model: WalletViewModel
    let root = UI.vbox(spacing: 0)
    private let list = UI.vbox(spacing: 0)
    private let note = PortfolioStateNote()
    private var shown: (tokens: [AssetBalance], empty: String?)?
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        root.setChildren([list, note.root])
        tracker = Tracker { [unowned self] in self.update() }
    }

    private func update() {
        let tokens = model.visibleTokens
        let state = model.portfolioState
        note.state = state
        let empty: String? = tokens.isEmpty
            ? (model.isLoading ? "Loading…" : (state.isUnavailable ? "Token data is unavailable." : model.layerEmptyText(for: "tokens") ?? "No tokens in this account."))
            : nil
        if let shown, shown.tokens == tokens, shown.empty == empty { return }
        shown = (tokens, empty)
        if let empty {
            list.setChildren([EmptyListText.make(empty)])
            return
        }
        let network = model.network
        var children: [Widget] = []
        for token in tokens {
            children.append(TokenRowView.make(token: token, network: network))
            children.append(UI.separator().margins(start: 56))
        }
        list.setChildren(children)
    }
}

/// A line under the Assets and NFTs tabs when the list is not the whole story (S26).
@MainActor
final class PortfolioStateNote {
    let root: Widget
    private let text = UI.label(classes: ["caption"], wrap: true)

    init() {
        root = UI.hbox(spacing: 6, [UI.image(icon: "dialog-warning-symbolic", pixelSize: 12), text.expand(h: true)])
        root.classes("portfolio-note").margins(top: 6, bottom: 6)
        root.isVisible = false
    }

    var state: Portfolio.State = .complete {
        didSet {
            switch state {
            case .complete:
                root.isVisible = false
            case .partial(let fetched):
                UI.setText(text, "Showing the \(fetched) most recently changed tokens; older holdings may be missing.")
                root.isVisible = true
            case .unavailable(let reason):
                UI.setText(text, "The indexer could not be read (\(reason)). Showing the last known list.")
                gtk_label_set_lines(text.opaque, 2)
                gtk_label_set_ellipsize(text.opaque, PANGO_ELLIPSIZE_END)
                root.isVisible = true
            }
        }
    }
}

extension Portfolio.State {
    var isUnavailable: Bool { if case .unavailable = self { return true } else { return false } }
}

@MainActor
enum TokenRowView {
    static func make(token: AssetBalance, network: Network) -> Widget {
        var contract: String?
        if case .token(let address, _) = token.kind { contract = address }
        // The explorer the token's contract is on: Etherlink's for a layer 2 token.
        let explorer = token.isLayer2 ? network.layer2 : network

        let logo = RemoteImage.make(urls: token.iconURLs, size: 40, round: true) {
            UI.circle(UI.label(String(token.symbol.prefix(3)), classes: ["caption-heading", "dim-label"], xalign: 0.5), size: 40, classes: "token-placeholder")
        }
        let name = UI.label(token.name, classes: ["transaction-headline"])
        gtk_label_set_ellipsize(name.opaque, PANGO_ELLIPSIZE_END)
        var details: [Widget] = []
        if let contract {
            details.append(UI.label(Address(contract).shortened(), classes: ["address", "dim-label"]))
        }
        if let standard = token.standard {
            details.append(UI.label(standard.uppercased(), classes: ["standard-tag"]).align(v: GTK_ALIGN_CENTER))
        }
        let text = UI.vbox(spacing: 2, [name, UI.hbox(spacing: 6, details)]).expand(h: true).align(v: GTK_ALIGN_CENTER)
        var amount: [Widget] = []
        if token.isLayer2 { amount.append(EtherlinkMark.make()) }
        amount.append(UI.label(token.formattedAmount, classes: ["numeric"], xalign: 1))

        let row = UI.hbox(spacing: 12, [logo, text, UI.hbox(spacing: 5, amount).align(v: GTK_ALIGN_CENTER)]).margins(top: 8, bottom: 8)
        row.tooltip((token.isLayer2 ? "On Etherlink\n" : "") + (contract.map { "\(token.name)\n\($0)" } ?? token.name))
        row.accessibleLabel("\(token.name) \(token.formattedAmount)\(token.isLayer2 ? ", on Etherlink" : "")")
        if let contract {
            var items: [(String, @MainActor () -> Void)] = [("Copy contract address", { UI.copyToClipboard(contract, from: row) })]
            if let url = explorer?.explorerURL(contract: contract) {
                items.append(("View in explorer", { UI.open(url, from: row) }))
            }
            UI.contextMenu(row, items)
        }
        return row
    }
}

/// Grid of NFT thumbnails at the bottom of the default screen. Tiles select like files in a
/// file manager (click, Ctrl-click to add, Shift-click for a range) and a right-click opens the
/// menu for the clicked tile, or for the whole selection when it is part of one.
@MainActor
final class NFTGridView {
    let model: WalletViewModel
    let root: Widget
    private let note = PortfolioStateNote()
    private let body = UI.vbox(spacing: 0)
    private var shown: (nfts: [NFT], empty: String?)?
    private var tiles: [NFT.ID: Widget] = [:]
    private var selection: Set<NFT.ID> = [] { didSet { showSelection() } }
    /// Where a Shift-click range starts: the last tile clicked without Shift.
    private var anchor: NFT.ID?
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        root = UI.vbox(spacing: 10, [note.root, body]).size(height: 180)
        tracker = Tracker { [unowned self] in self.update() }
    }

    private var nfts: [NFT] { shown?.nfts ?? [] }

    private func update() {
        let nfts = model.visibleNFTs
        let state = model.portfolioState
        note.state = state
        let empty: String? = nfts.isEmpty
            ? (model.isLoading ? "Loading…" : (state.isUnavailable ? "NFT data is unavailable." : model.layerEmptyText(for: "NFTs") ?? "No NFTs in this account."))
            : nil
        if let shown, shown.nfts == nfts, shown.empty == empty { return }
        shown = (nfts, empty)
        tiles = [:]
        // `.onChange(of: nfts.map(\.id))`: what is gone leaves the selection.
        selection = selection.intersection(nfts.map(\.id))
        if let empty {
            body.setChildren([EmptyListText.make(empty)])
            return
        }
        // `LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)])`.
        let grid = Widget(gtk_flow_box_new()!)
        gtk_flow_box_set_selection_mode(grid.opaque, GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(grid.opaque, 1)
        gtk_flow_box_set_column_spacing(grid.opaque, 12)
        gtk_flow_box_set_row_spacing(grid.opaque, 16)
        gtk_flow_box_set_min_children_per_line(grid.opaque, 2)
        gtk_flow_box_set_max_children_per_line(grid.opaque, 12)
        grid.margins(top: 2, bottom: 2)
        for nft in nfts {
            let tile = NFTTileView.make(nft: nft)
            tiles[nft.id] = tile
            UI.onClick(tile, modifiers: { [unowned self] modifiers, _, _ in self.click(nft, modifiers: modifiers) })
            UI.contextMenu(tile, build: { [unowned self] in self.menu(for: nft, on: tile) })
            gtk_flow_box_append(grid.opaque, tile.pointer)
        }
        // A click between the tiles clears the selection.
        UI.onClick(grid, modifiers: { [unowned self] _, x, y in
            if gtk_flow_box_get_child_at_pos(grid.opaque, Int32(x), Int32(y)) == nil { self.selection = [] }
        })
        body.setChildren([grid])
        showSelection()
    }

    private func menu(for nft: NFT, on tile: Widget) -> [UI.MenuEntry] {
        var deselect: (@MainActor () -> Void)?
        if !selection.isEmpty { deselect = { [unowned self] in self.selection = [] } }
        let all = Set(nfts.map(\.id))
        return NFTContextMenu.entries(targets: targets(for: nft), model: model, from: tile, canSelectAll: selection.count < nfts.count,
                                      selectAll: { [unowned self] in self.selection = all }, deselect: deselect)
    }

    private func showSelection() {
        for (id, tile) in tiles { tile.setClass("selected-tile", selection.contains(id)) }
    }

    /// The tokens a menu on `nft` acts on: the selection when the tile is in it, else that tile alone.
    private func targets(for nft: NFT) -> [NFT] {
        selection.contains(nft.id) ? nfts.filter { selection.contains($0.id) } : [nft]
    }

    private func click(_ nft: NFT, modifiers: UI.ClickModifiers) {
        if modifiers.contains(.control) {
            if selection.contains(nft.id) { selection.remove(nft.id) } else { selection.insert(nft.id) }
        } else if modifiers.contains(.shift), let anchor, let from = nfts.firstIndex(where: { $0.id == anchor }), let to = nfts.firstIndex(where: { $0.id == nft.id }) {
            selection = Set(nfts[min(from, to)...max(from, to)].map(\.id))
            return
        } else {
            selection = [nft.id]
        }
        anchor = nft.id
    }
}

/// The right-click menu of one tile or of the selection: Transfer and Burn when the account
/// can sign for its tokens (never for a selection spanning Tezos and Etherlink, or a soulbound
/// token), Download for the artwork, then the links and copies of a single token, then selection.
@MainActor
enum NFTContextMenu {
    static func entries(targets: [NFT], model: WalletViewModel, from widget: Widget, canSelectAll: Bool,
                        selectAll: @escaping @MainActor () -> Void, deselect: (@MainActor () -> Void)?) -> [UI.MenuEntry] {
        let layer = targets.first?.layer ?? 1
        let sameLayer = Set(targets.map(\.layer)).count == 1
        let transferable = targets.allSatisfy(\.isTransferable)
        let canOperate = sameLayer && transferable && targets.count <= TokenTransferRequest.maxTokens && model.canTransferTokens(on: layer)
        let plural = targets.count == 1 ? "" : " \(targets.count) NFTs"

        var entries: [UI.MenuEntry] = [
            .item("Transfer\(plural)…", enabled: canOperate) { model.nftOperation = NFTOperation(kind: .transfer, nfts: targets) },
            .item("Burn\(plural)…", enabled: canOperate, destructive: true) { model.nftOperation = NFTOperation(kind: .burn, nfts: targets) },
        ]
        // Why Transfer and Burn are off, when they are.
        let reason: String? = if !sameLayer { "Choose NFTs on one chain at a time" }
            else if !transferable { targets.count == 1 ? "This token cannot be transferred" : "One of these tokens cannot be transferred" }
            else if targets.count > TokenTransferRequest.maxTokens { "At most \(TokenTransferRequest.maxTokens) NFTs at once" }
            else if !model.canTransferTokens(on: layer) { layer == 2 ? "Signet cannot sign for this account on Etherlink" : "Signet cannot sign for this account" }
            else { nil }
        if let reason { entries.append(.note(reason)) }
        entries.append(.separator)
        entries.append(.item("Download\(plural)…", enabled: targets.allSatisfy { !$0.artifactURLs.isEmpty || !$0.imageURLs.isEmpty }) {
            model.nftDownload = NFTDownload(nfts: targets)
        })
        if targets.count == 1, let nft = targets.first {
            let network = model.tokenNetwork(on: nft.layer)
            if let url = network.explorerURL(token: nft.contract, id: nft.tokenId) {
                entries.append(.item("Open in Explorer") { UI.open(url, from: widget) })
            }
            if let url = network.objktURL(token: nft.contract, id: nft.tokenId) {
                entries.append(.item("Open on objkt.com") { UI.open(url, from: widget) })
            }
            if let url = nft.artifactURLs.first {
                entries.append(.item(nft.isMoving ? "View Artwork (plays in the browser)" : "View Artwork") { UI.open(url, from: widget) })
            }
            entries.append(.separator)
            entries.append(.item("Copy Contract Address") { UI.copyToClipboard(nft.contract, from: widget) })
            entries.append(.item("Copy Token ID") { UI.copyToClipboard(nft.tokenId, from: widget) })
        }
        entries.append(.separator)
        entries.append(.item("Select All", enabled: canSelectAll, action: selectAll))
        if let deselect { entries.append(.item("Deselect All", action: deselect)) }
        return entries
    }
}

@MainActor
enum NFTTileView {
    static let size: Int32 = 128

    static func make(nft: NFT) -> Widget {
        let thumbnail = RemoteImage.make(urls: nft.imageURLs, size: size, round: false) {
            placeholder(icon: nft.imageURLs.isEmpty ? "image-x-generic-symbolic" : nil)
        }
        let frame = Widget(gtk_overlay_new()!)
        gtk_overlay_set_child(frame.opaque, thumbnail.pointer)
        frame.classes("nft-tile").size(width: size, height: size).align(h: GTK_ALIGN_START)
        gtk_widget_set_overflow(frame.pointer, GTK_OVERFLOW_HIDDEN)

        if nft.isLayer2 {
            let mark = UI.circle(EtherlinkMark.make(size: 16), size: 22, classes: "tile-chip")
            overlay(mark, on: frame, h: GTK_ALIGN_START, v: GTK_ALIGN_START)
        }
        if nft.isMoving {
            let audio = nft.artifactMime?.hasPrefix("audio/") == true
            let chip = UI.image(icon: audio ? "audio-volume-high-symbolic" : "media-playback-start-symbolic", pixelSize: 10).classes("tile-chip")
            chip.tooltip(audio ? "A sound: the tile shows its cover image" : "A video: the tile shows its still image")
            overlay(chip, on: frame, h: GTK_ALIGN_END, v: GTK_ALIGN_END)
        }
        if nft.balance > 1 {
            overlay(UI.label("×\(nft.balance)", classes: ["tile-chip", "caption-heading"]), on: frame, h: GTK_ALIGN_END, v: GTK_ALIGN_START)
        }
        let name = UI.label(nft.name, classes: ["caption", "dim-label", "nft-name"])
        gtk_label_set_ellipsize(name.opaque, PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(name.opaque, 1)
        let tile = UI.vbox(spacing: 6, [frame, name]).size(width: size)
        tile.tooltip((nft.isLayer2 ? "On Etherlink\n" : "") + "\(nft.name)\n\(nft.contract) #\(nft.tokenId)")
        tile.accessibleLabel(nft.name + (nft.isMoving ? ", video or sound" : "") + (nft.isLayer2 ? ", on Etherlink" : ""))
        return tile
    }

    private static func overlay(_ widget: Widget, on frame: Widget, h: GtkAlign, v: GtkAlign) {
        widget.align(h: h, v: v).margins(6)
        gtk_overlay_add_overlay(frame.opaque, widget.pointer)
    }

    private static func placeholder(icon: String?) -> Widget {
        let inner = icon.map { UI.image(icon: $0, pixelSize: 24).classes("dim-label") } ?? Widget(gtk_spinner_new()!)
        if icon == nil { gtk_spinner_start(inner.opaque) }
        inner.align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER).expand(h: true, v: true)
        return UI.vbox(spacing: 0, [inner]).size(width: size, height: size).classes("nft-placeholder")
    }
}
