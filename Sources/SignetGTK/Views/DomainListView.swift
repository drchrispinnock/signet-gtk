import CAdwaita
import Foundation

/// The Domains tab: the account's Tezos Domains names, the one it publishes as its own first,
/// each with where it points, who owns it and when it expires. The GTK counterpart of
/// upstream's `Views/DomainListView.swift`.
@MainActor
final class DomainListView {
    let model: WalletViewModel
    let root = UI.vbox(spacing: 0)
    private var shown: (key: String?, state: WalletViewModel.DomainListState?)?
    private var trackers: [Tracker] = []
    private var loading: Task<Void, Never>?
    private var loadedKey: String??

    init(model: WalletViewModel) {
        self.model = model
        // `.task(id: model.domainListKey) { await model.loadDomainList() }`.
        trackers.append(Tracker { [unowned self] in
            let key = self.model.domainListKey
            guard self.loadedKey != .some(key) else { return }
            self.loadedKey = .some(key)
            self.loading?.cancel()
            self.loading = Task { [model] in await model.loadDomainList() }
        })
        trackers.append(Tracker { [unowned self] in self.update() })
    }

    isolated deinit { loading?.cancel() }

    private func update() {
        let key = model.domainListKey, state = model.currentDomainList
        if let shown, shown.key == key, shown.state == state { return }
        shown = (key, state)
        switch state {
        case nil, .loading?:
            root.setChildren([EmptyListText.make("Loading…")])
        case .unavailable?:
            root.setChildren([EmptyListText.make("Tezos Domains names exist on Mainnet only.")])
        case .failed(let reason)?:
            let retry = UI.button("Try Again") { [model] in Task { await model.reloadDomainList() } }
            root.setChildren([UI.vbox(spacing: 8, [EmptyListText.make("Tezos Domains could not be read: \(reason)"), retry.align(h: GTK_ALIGN_CENTER)])])
        case .loaded(let domains)?:
            if domains.isEmpty {
                root.setChildren([EmptyListText.make("No .tez names belong to or point at this account.")])
            } else if let account = model.selectedWallet?.address {
                var children: [Widget] = []
                for domain in domains {
                    children.append(DomainRowView.make(domain: domain, account: account, model: model))
                    children.append(UI.separator().margins(start: 56))
                }
                root.setChildren(children)
            }
        }
    }
}

@MainActor
enum DomainRowView {
    static func make(domain: TezosDomain, account: Address, model: WalletViewModel) -> Widget {
        let icon = UI.circle(UI.image(icon: domain.isReverseRecord ? "avatar-default-symbolic" : "web-browser-symbolic", pixelSize: 18),
                             size: 40, classes: "domain-icon")
        let name = UI.label(domain.name, classes: ["transaction-headline"])
        gtk_label_set_selectable(name.opaque, 1)
        gtk_label_set_ellipsize(name.opaque, PANGO_ELLIPSIZE_END)
        var nameRow = [name]
        if domain.isReverseRecord {
            nameRow.append(UI.label("Primary name").classes("tag").align(v: GTK_ALIGN_CENTER)
                .tooltip("The account's reverse record: the name wallets and explorers show for this address."))
        }
        let detailLabel = UI.label(detail(domain: domain, account: account, model: model), classes: ["dim-label"])
        gtk_label_set_ellipsize(detailLabel.opaque, PANGO_ELLIPSIZE_END)
        let text = UI.vbox(spacing: 3, [UI.hbox(spacing: 6, nameRow), detailLabel]).expand(h: true).align(v: GTK_ALIGN_CENTER)

        let row = UI.hbox(spacing: 12, [icon.align(v: GTK_ALIGN_CENTER), text, expiry(domain).align(v: GTK_ALIGN_CENTER)]).classes("transaction-row")
        UI.contextMenu(row, build: { [weak model] in
            var entries: [UI.MenuEntry] = []
            if let model, model.canTransferDomain(domain) {
                entries += [.item("Transfer…") { model.domainOperation = domain }, .separator]
            }
            entries.append(.item("Copy Name") { UI.copyToClipboard(domain.name, from: row) })
            if let address = domain.address { entries.append(.item("Copy Address It Points To") { UI.copyToClipboard(address.value, from: row) }) }
            if let url = domain.appURL { entries.append(.item("Open on Tezos Domains") { UI.open(url, from: row) }) }
            return entries
        })
        return row
    }

    /// Who owns it and where it points, in words.
    private static func detail(domain: TezosDomain, account: Address, model: WalletViewModel) -> String {
        let target = domain.address.map { domain.pointsAt(account) ? "this account" : model.displayName(for: $0, indexerAlias: nil).name }
        let points = target.map { "Points to \($0)" } ?? "Points nowhere"
        if domain.isOwned(by: account) { return "Owned by this account · \(points)" }
        let owner = domain.owner.map { model.displayName(for: $0, indexerAlias: nil).name } ?? "someone else"
        return "\(points) · owned by \(owner)"
    }

    private static func expiry(_ domain: TezosDomain) -> Widget {
        guard let expires = domain.expires else {
            return UI.label("Subdomain", classes: ["dim-label", "caption"], xalign: 1).tooltip("A subdomain lasts as long as its parent name.")
        }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0
        let date = UI.label(expires.formatted(date: .abbreviated, time: .omitted), classes: ["numeric"], xalign: 1)
        if days < 0 { date.classes("error") } else if days < 30 { date.classes("warning") }
        return UI.vbox(spacing: 2, [UI.label(days < 0 ? "Expired" : "Expires", classes: ["dim-label", "caption"], xalign: 1), date])
            .tooltip(days < 0 ? "This name has expired; anyone may register it." : days < 30 ? "Renew it on Tezos Domains before it expires." : nil)
    }
}
