import CAdwaita
import Foundation

/// Left side of the header: avatar, alias (a dropdown that switches wallets) and its tags,
/// shortened address with a copy button, then any Tezos Domains names. The GTK counterpart of
/// upstream's `WalletIdentityView` in `Views/WalletHeaderView.swift`.
@MainActor
final class WalletIdentityView {
    let model: WalletViewModel
    let root: Widget
    private let avatar: AccountAvatarView
    private let picker: Widget
    private let aliasLabel = UI.label(classes: ["alias"])
    private let tags = UI.hbox(spacing: 6)
    private let address = UI.label(classes: ["address", "dim-label"])
    private let copyButton: Widget
    private let domains = UI.vbox(spacing: 2)
    private var copied = false
    private var trackers: [Tracker] = []

    init(model: WalletViewModel, wallet: Wallet) {
        self.model = model
        avatar = AccountAvatarView(address: wallet.address, size: 48)
        let chevron = UI.image(icon: "pan-down-symbolic", pixelSize: 12).classes("dim-label")
        picker = MenuButtons.make(content: UI.hbox(spacing: 6, [aliasLabel, chevron]), classes: ["account-picker"])
        picker.tooltip("Switch account")
        copyButton = UI.iconButton("edit-copy-symbolic", tooltip: "Copy address") {}
        let addressRow = UI.hbox(spacing: 6, [address, copyButton])
        let identity = UI.vbox(spacing: 4, [UI.hbox(spacing: 8, [picker, tags]), addressRow, domains]).align(v: GTK_ALIGN_CENTER)
        root = UI.hbox(spacing: 12, [avatar.root.align(v: GTK_ALIGN_CENTER), identity])
        Signals.connect(copyButton, "clicked") { [weak self] in self?.copyAddress() }
        trackers.append(Tracker { [unowned self] in self.update() })
    }

    private var wallet: Wallet? { model.selectedWallet }

    private func update() {
        guard let wallet else { return }
        avatar.address = wallet.address
        UI.setText(aliasLabel, wallet.alias)
        picker.accessibleLabel("Account \(wallet.alias). Switch account")
        UI.setText(address, wallet.address.shortened())
        address.tooltip(wallet.address.value)

        var tagWidgets: [Widget] = []
        if wallet.address.isContract {
            tagWidgets.append(tag("Contract", icon: "x-office-document-symbolic"))
        } else if wallet.keyKind == .none {
            tagWidgets.append(tag("Watch only", icon: "view-reveal-symbolic").tooltip("Signet has no key for this address; you can watch it and send to it."))
        }
        if wallet.keyKind == .ledger {
            tagWidgets.append(tag("Ledger", icon: "media-removable-symbolic")
                .tooltip("This key lives on a Ledger\(wallet.ledgerKey.map { " (\($0.fullPath))" } ?? ""). Operations are approved on the device."))
        }
        if wallet.isSessionOnly {
            // Orange, unlike the other tags: this key is lost at quit unless Remember key is used.
            tagWidgets.append(tag("Session only", icon: "alarm-symbolic").classes("session")
                .tooltip("A paper key held in memory only. It is not in the wallet directory or any backup and is forgotten when Signet quits. Use Remember key… in the menu to keep it."))
        }
        tags.setChildren(tagWidgets)
        domains.setChildren(model.domains.map { UI.label($0, classes: ["dim-label"]) })
        updatePicker(selected: wallet)
    }

    /// The alias doubles as the wallet switcher: my accounts, the address book, contracts.
    private func updatePicker(selected: Wallet) {
        let menu = MenuBuilder()
        let mine = model.wallets.filter { $0.keyKind != .none }
        let book = model.wallets.filter { $0.keyKind == .none && !$0.address.isContract }
        let contracts = model.wallets.filter { $0.address.isContract }
        for (heading, group) in [("My accounts", mine), ("Address book", book), ("Contracts", contracts)] where !group.isEmpty {
            menu.section(heading)
            for candidate in group {
                menu.choice("\(candidate.alias)  \(candidate.address.shortened())", action: Operations.selectAccount, value: Operations.key(for: candidate))
            }
        }
        MenuButtons.setMenu(picker, menu)
    }

    private func tag(_ text: String, icon: String) -> Widget {
        UI.hbox(spacing: 3, [UI.image(icon: icon, pixelSize: 10), UI.label(text)]).classes("tag").align(v: GTK_ALIGN_CENTER)
    }

    private func copyAddress() {
        guard let wallet else { return }
        UI.copyToClipboard(wallet.address.value, from: root)
        gtk_button_set_icon_name(copyButton.as(), "object-select-symbolic")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            gtk_button_set_icon_name(self.copyButton.as(), "edit-copy-symbolic")
        }
    }
}

/// The hamburger menu in the top-right corner: app-level actions, not wallet switching.
@MainActor
final class AppMenuButton {
    let root = MenuButtons.make(icon: "open-menu-symbolic", tooltip: "Menu")
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        tracker = Tracker { [unowned self] in MenuButtons.setMenu(self.root, Operations.menu(model: model)) }
    }
}

/// The one list of account actions, shared by the burger menu and the keyboard shortcuts so the
/// two can never drift: order, dividers, visibility and enabling. Upstream's
/// `OperationsMenuItems`; the Mac's menu bar has no counterpart here, so its shortcuts are the
/// window's (Ctrl in place of Cmd).
@MainActor
enum Operations {
    struct Sheet {
        let action: String
        let title: String
        let flag: ReferenceWritableKeyPath<WalletViewModel, Bool>
    }

    /// Every sheet a menu item or start option opens, with the name its action goes by.
    static let sheets: [Sheet] = [
        Sheet(action: "create-account", title: "Create account", flag: \.isPresentingCreateWallet),
        Sheet(action: "import-account", title: "Import account", flag: \.isPresentingImportAccount),
        Sheet(action: "connect-ledger", title: "Connect Ledger", flag: \.isPresentingConnectLedger),
        Sheet(action: "rename-account", title: "Rename account", flag: \.isPresentingRenameWallet),
        Sheet(action: "export-key", title: "Export secret key", flag: \.isPresentingExportKey),
        Sheet(action: "prove-possession", title: "Create proof of possession", flag: \.isPresentingProofOfPossession),
        Sheet(action: "add-address", title: "Add address", flag: \.isPresentingAddAddress),
        Sheet(action: "remember-key", title: "Remember key", flag: \.isPresentingRememberKey),
        Sheet(action: "forget-account", title: "Forget account", flag: \.isPresentingForget),
        Sheet(action: "dapps", title: "dApps", flag: \.isPresentingConnectDApp),
        Sheet(action: "bridge", title: "Bridge", flag: \.isPresentingBridge),
        Sheet(action: "shield", title: "Shield tez", flag: \.isPresentingShield),
        Sheet(action: "unshield", title: "Unshield tez", flag: \.isPresentingUnshield),
        Sheet(action: "send-shielded", title: "Send shielded", flag: \.isPresentingSendShielded),
        Sheet(action: "shielded-address", title: "Shielded address", flag: \.isPresentingShieldedAddress),
        Sheet(action: "create-multisig", title: "Create multisig", flag: \.isPresentingCreateMultisig),
        Sheet(action: "add-multisig", title: "Add multisig", flag: \.isPresentingAddMultisig),
        Sheet(action: "sign-multisig", title: "Sign multisig transaction", flag: \.isPresentingSignMultisig),
        Sheet(action: "submit-multisig", title: "Submit multisig transaction", flag: \.isPresentingSubmitMultisig),
        Sheet(action: "baking", title: "Baking", flag: \.isPresentingBaking),
        Sheet(action: "governance", title: "Governance", flag: \.isPresentingGovernance),
        Sheet(action: "networks", title: "Networks", flag: \.isPresentingNetworks),
        Sheet(action: "shield-settings", title: "Shielded settings", flag: \.isPresentingShieldSettings),
        Sheet(action: "send", title: "Send", flag: \.isPresentingSend),
        Sheet(action: "receive", title: "Receive", flag: \.isPresentingReceive),
        Sheet(action: "staking", title: "Staking", flag: \.isPresentingStaking),
        Sheet(action: "buy", title: "Buy", flag: \.isPresentingBuy),
        Sheet(action: "faucet", title: "Faucet", flag: \.isPresentingFaucet),
    ]

    static let selectAccount = "select-account"
    static let selectNetwork = "select-network"

    /// A wallet's key in the account switcher: alias and address, as aliases are unique per
    /// directory but session keys sit beside it.
    static func key(for wallet: Wallet) -> String { "\(wallet.address.value)\u{1F}\(wallet.alias)" }

    static func install(on actions: Actions, app: Widget, model: WalletViewModel) {
        for sheet in sheets {
            actions.add(sheet.action) { model[keyPath: sheet.flag] = true }
        }
        // Settings is a window of its own upstream; not ported yet.
        actions.add("settings") { unported?("Settings is not available on Linux yet.") }
        actions.add("refresh") { Task { await model.refresh() } }
        actions.add("quit") { g_application_quit(app.as()) }
        actions.addChoice(selectAccount, current: "") { key in
            if let wallet = model.wallets.first(where: { Self.key(for: $0) == key }) { model.select(wallet) }
        }
        actions.addChoice(selectNetwork, current: model.network.name) { name in
            if let base = Network.all.first(where: { $0.name == name }) { model.switchNetwork(to: base) }
        }
        // Enabling and the radio states follow the model.
        let tracker = Tracker {
            let selected = model.selectedWallet != nil
            actions.setEnabled("rename-account", selected)
            actions.setEnabled("export-key", model.canExportSelectedKey)
            actions.setEnabled("forget-account", selected)
            actions.setEnabled("baking", selected)
            actions.setEnabled("refresh", selected)
            actions.setChoice(selectAccount, model.selectedWallet.map(key(for:)) ?? "")
            actions.setChoice(selectNetwork, model.network.name)
        }
        trackers.append(tracker)
    }

    private static var trackers: [Tracker] = []

    /// Shows a note for something not ported yet (set by the window).
    static var unported: ((String) -> Void)?

    static func installShortcuts(app: Widget) {
        let shortcuts: [(String, String)] = [
            ("create-account", "<Control>n"),
            ("import-account", "<Control><Shift>i"),
            ("connect-ledger", "<Control><Shift>l"),
            ("add-address", "<Control><Shift>n"),
            ("dapps", "<Control><Shift>d"),
            ("settings", "<Control>comma"),
            ("refresh", "<Control>r"),
            ("quit", "<Control>q"),
        ]
        for (action, accel) in shortcuts {
            accel.withCString { accelPointer in
                var accels: [UnsafePointer<CChar>?] = [accelPointer, nil]
                gtk_application_set_accels_for_action(app.as(), "win.\(action)", &accels)
            }
        }
    }

    /// The burger menu, item for item as upstream's `OperationsMenuItems`.
    static func menu(model: WalletViewModel) -> MenuBuilder {
        let menu = MenuBuilder()
        menu.section()
            .item("Create account…", action: "create-account")
            .item("Import account…", action: "import-account")
            .item("Connect Ledger…", action: "connect-ledger")
            .item("Rename account…", action: "rename-account")
            .item("Export secret key…", action: "export-key")
        if model.canProveSelectedKey { menu.item("Create proof of possession…", action: "prove-possession") }
        menu.section().item("Add address…", action: "add-address")
        if model.canRememberSelectedKey { menu.item("Remember key…", action: "remember-key") }
        menu.item("Forget account…", action: "forget-account")
        menu.section().item("dApps…", action: "dapps")
        if model.canBridge { menu.item("Bridge…", action: "bridge") }
        if model.canShield {
            menu.section()
                .item("Shield tez…", action: "shield")
                .item("Unshield tez…", action: "unshield")
                .item("Send shielded…", action: "send-shielded")
                .item("Shielded address…", action: "shielded-address")
        }
        menu.section()
            .item("Create multisig…", action: "create-multisig")
            .item("Add multisig…", action: "add-multisig")
            .item("Sign multisig transaction…", action: "sign-multisig")
            .item("Submit multisig transaction…", action: "submit-multisig")
        menu.section().item("Baking…", action: "baking")
        if model.canGovern { menu.item("Governance…", action: "governance") }
        menu.section()
            .item("Networks…", action: "networks")
            .item("Shielded settings…", action: "shield-settings")
            .item("Settings…", action: "settings")
            .item("Refresh", action: "refresh")
        return menu
    }
}
