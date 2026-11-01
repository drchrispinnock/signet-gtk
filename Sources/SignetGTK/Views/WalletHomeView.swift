import CAdwaita
import Foundation

/// The single window: a header bar (the window's title and controls, which the Mac draws for
/// itself) above `WalletHomeView`. Holds the window actions the menus and shortcuts use.
@MainActor
enum MainWindow {
    static func make(app: Widget, model: WalletViewModel) -> Widget {
        let window = Widget(adw_application_window_new(app.as())!)
        gtk_window_set_title(window.as(), "Signet")
        gtk_window_set_default_size(window.as(), 560, 780)
        // `.frame(minWidth: 480, minHeight: 720)` upstream.
        window.size(width: 480, height: 720)

        let actions = Actions(window: window)
        let home = WalletHomeView(model: model, actions: actions)
        Operations.install(on: actions, app: app, model: model)
        Operations.installShortcuts(app: app)

        let header = Widget(adw_header_bar_new()!)
        let toolbar = Widget(adw_toolbar_view_new()!)
        adw_toolbar_view_add_top_bar(toolbar.opaque, header.pointer)
        adw_toolbar_view_set_content(toolbar.opaque, home.root.pointer)
        adw_application_window_set_content(window.as(), toolbar.pointer)
        window.retain(home)
        return window
    }
}

/// The default screen from spec/EXAMPLE.png: header, action row, asset list, NFT grid. With no
/// wallets yet it shows a prompt to create the first address instead. The GTK counterpart of
/// upstream's `Views/WalletHomeView.swift`.
@MainActor
final class WalletHomeView {
    let model: WalletViewModel
    let root: Widget
    private let toasts: Widget
    private let content = UI.vbox(spacing: 24)
    private let errorLabel = UI.label(classes: ["error-message"], wrap: true, xalign: 0.5)
    private var trackers: [Tracker] = []
    /// Which kind of screen `content` holds, so it is rebuilt only when that changes.
    private var shownWallet: Wallet.ID?? = .none
    private var dashboard: DashboardView?
    private var welcome: NoWalletsView?

    init(model: WalletViewModel, actions: Actions) {
        self.model = model
        content.margins(24).expand(h: true, v: true).align(v: GTK_ALIGN_FILL)
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, content.pointer)
        scroller.expand(h: true, v: true)

        errorLabel.margins(top: 8, bottom: 8, start: 8, end: 8)
        let status = NodeStatusBar(monitor: model.nodeMonitor, layer2: model.l2Monitor)
        let column = UI.vbox(spacing: 0, [scroller, errorLabel, UI.separator(), status.root])
        column.retain(status, key: "signet-status")

        toasts = Widget(adw_toast_overlay_new()!)
        adw_toast_overlay_set_child(toasts.opaque, column.pointer)
        root = toasts

        self.actions = actions
        Operations.unported = { [weak self] in self?.showToast($0) }
        Operations.presentSettings = { [weak self] in self?.presentSettings() }
        trackers.append(Tracker { [unowned self] in self.updateContent() })
        trackers.append(Tracker { [unowned self] in
            let message = self.model.errorMessage
            UI.setText(self.errorLabel, message ?? "")
            self.errorLabel.isVisible = message != nil
        })
        trackers.append(Tracker { [unowned self] in self.presentSheets() })

        // `.task` upstream: start watching the nodes and load the account.
        model.nodeMonitor.start()
        model.l2Monitor.start()
        Task { await model.refresh() }
    }

    private let actions: Actions

    /// The account dashboard or, with no accounts, the welcome screen.
    private func updateContent() {
        let wallet = model.selectedWallet
        guard shownWallet != .some(wallet?.id) else { return }
        shownWallet = .some(wallet?.id)
        if let wallet {
            let dashboard = DashboardView(model: model, wallet: wallet)
            self.dashboard = dashboard
            welcome = nil
            content.setChildren(dashboard.children)
        } else {
            let welcome = NoWalletsView(model: model)
            self.welcome = welcome
            dashboard = nil
            content.setChildren([welcome.root])
        }
    }

    /// The sheets on screen, by their action name.
    private var presented: [String: Sheet] = [:]

    /// Upstream presents a sheet for each `isPresenting…` flag: the same here, and a sheet not
    /// ported yet says so and lowers its flag, so the menu item can be used again. A sheet whose
    /// flag the model lowers is closed; one the user closes lowers its flag.
    private func presentSheets() {
        for sheet in Operations.sheets {
            let wanted = model[keyPath: sheet.flag]
            if let shown = presented[sheet.action] {
                if !wanted { shown.dismiss() }
                continue
            }
            guard wanted else { continue }
            guard let view = makeSheet(sheet.action) else {
                model[keyPath: sheet.flag] = false
                showToast("\(sheet.title) is not available on Linux yet.")
                continue
            }
            presented[sheet.action] = view
            view.onClosed = { [weak self, model] in
                self?.presented[sheet.action] = nil
                if model[keyPath: sheet.flag] { model[keyPath: sheet.flag] = false }
            }
            view.present(over: root)
        }
    }

    private func presentSettings() {
        guard presented["settings"] == nil else { return }
        let view = SettingsView(model: model)
        presented["settings"] = view
        view.onClosed = { [weak self] in self?.presented["settings"] = nil }
        view.present(over: root)
    }

    private func makeSheet(_ action: String) -> Sheet? {
        switch action {
        case "create-account": CreateWalletSheet(model: model)
        case "rename-account": RenameWalletSheet(model: model)
        case "add-address": AddAddressSheet(model: model)
        case "forget-account": ForgetAccountSheet(model: model)
        case "export-key": ExportKeySheet(model: model)
        case "remember-key": RememberKeySheet(model: model)
        case "prove-possession": ProofOfPossessionSheet(model: model)
        case "import-account": ImportAccountSheet(model: model)
        case "faucet": FaucetSheet(model: model)
        case "baking": BakingSheet(model: model)
        case "connect-ledger": ConnectLedgerSheet(model: model)
        case "networks": NetworksSheet(model: model)
        case "staking": StakingSheet(model: model)
        case "send": model.selectedWallet.map { SendSheet(model: model, sender: $0) }
        case "receive": model.selectedWallet.map { ReceiveSheet(model: model, wallet: $0, domains: model.domains) }
        default: nil
        }
    }

    func showToast(_ text: String) {
        let toast = adw_toast_new(text)!
        adw_toast_overlay_add_toast(toasts.opaque, toast)
    }
}

/// The dashboard for one account: header, action row, then the balances and delegate (or why
/// the account has none), then the activity.
@MainActor
final class DashboardView {
    let model: WalletViewModel
    let wallet: Wallet
    let children: [Widget]
    private let identity: WalletIdentityView
    private let badge: NetworkBadgeMenu
    private let menu: AppMenuButton
    private let actions: ActionButtonsView
    private let activity: ActivityTabsView
    private let balances = UI.vbox(spacing: 24)
    private var assets: AssetListView?
    private var delegate: DelegateRowView?
    private var notOnChain: AccountNotOnChainView?
    private var tracker: Tracker?

    init(model: WalletViewModel, wallet: Wallet) {
        self.model = model
        self.wallet = wallet
        identity = WalletIdentityView(model: model, wallet: wallet)
        badge = NetworkBadgeMenu(model: model)
        menu = AppMenuButton(model: model)
        actions = ActionButtonsView(model: model)
        let header = UI.hbox(spacing: 8, [identity.root.expand(h: true), badge.root.align(v: GTK_ALIGN_START), menu.root.align(v: GTK_ALIGN_START)])
        activity = ActivityTabsView(model: model)
        children = [header, actions.root, balances, UI.separator(), activity.root]
        tracker = Tracker { [unowned self] in self.updateBalances() }
    }

    /// `if model.accountNotOnChain { AccountNotOnChainView } else { AssetListView; DelegateRowView }`
    private func updateBalances() {
        if model.accountNotOnChain {
            guard notOnChain == nil else { return }
            let view = AccountNotOnChainView(model: model, wallet: wallet)
            notOnChain = view
            assets = nil
            delegate = nil
            balances.setChildren([view.root])
        } else {
            guard assets == nil else { return }
            let list = AssetListView(model: model)
            let row = DelegateRowView(model: model)
            assets = list
            delegate = row
            notOnChain = nil
            balances.setChildren([list.root, row.root])
        }
    }
}

/// Shown when there is nothing to display yet.
@MainActor
final class NoWalletsView {
    let model: WalletViewModel
    let root: Widget
    private let importError = UI.label(classes: ["error-message"], wrap: true, xalign: 0.5)
    private let options = UI.vbox(spacing: 10)
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        let icon = UI.resourceImage("signet-256", "png", pixelSize: 96) ?? UI.image(icon: "avatar-default-symbolic", pixelSize: 96)
        // Upstream: "…a Tezos Wallet for the Mac."
        let title = UI.label("Welcome to Signet, a Tezos Wallet.", classes: ["welcome-title"], wrap: true, xalign: 0.5)
        let prompt = UI.label("How would you like to start?", classes: ["dim-label"], xalign: 0.5)
        options.size(width: 440).align(h: GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(options.pointer, 0)
        importError.isVisible = false
        root = UI.vbox(spacing: 20, [UI.spacer(), icon, title, prompt, options, importError, UI.spacer()]).expand(h: true, v: true)
        tracker = Tracker { [unowned self] in self.updateOptions() }
    }

    private var hasOctezWallet: Bool { model.importableWalletCount > 0 }

    private func updateOptions() {
        var rows = [
            // Upstream: "Generate a fresh key on this Mac, …"
            StartOption.make(title: "Create a new account", detail: "Generate a fresh key on this computer, protected with a password.",
                             symbol: "list-add-symbolic", prominent: true) { [model] in model.isPresentingCreateWallet = true },
            StartOption.make(title: "Import an existing account", detail: "From a secret key or a recovery phrase of 12 to 24 words.",
                             symbol: "dialog-password-symbolic") { [model] in model.isPresentingImportAccount = true },
            StartOption.make(title: "Connect a Ledger", detail: "Use a key that stays on your hardware wallet.",
                             symbol: "media-removable-symbolic") { [model] in model.isPresentingConnectLedger = true },
        ]
        if hasOctezWallet {
            let count = model.importableWalletCount
            rows.append(StartOption.make(
                title: "Import your octez-client wallet",
                detail: "Found \(count) \(count == 1 ? "account" : "accounts") in ~/.tezos-client. Copies the files into ~/.signet; octez-client keeps working.",
                symbol: "folder-download-symbolic"
            ) { [weak self] in self?.importWallets() })
        }
        options.setChildren(rows)
    }

    private func importWallets() {
        importError.isVisible = false
        do {
            try model.importFromOctezClient()
        } catch {
            UI.setText(importError, error.localizedDescription)
            importError.isVisible = true
        }
    }
}

/// One of the ways to start on a cold boot: an icon, a title, a line of detail and a chevron.
@MainActor
enum StartOption {
    static func make(title: String, detail: String, symbol: String, prominent: Bool = false, action: @escaping @MainActor () -> Void) -> Widget {
        let icon = UI.image(icon: symbol, pixelSize: 24).classes("symbol").size(width: 32)
        let text = UI.vbox(spacing: 2, [
            UI.label(title, classes: ["heading"]),
            UI.label(detail, classes: ["dim-label"], wrap: true),
        ]).expand(h: true)
        let chevron = UI.image(icon: "go-next-symbolic", pixelSize: 12).classes("dim-label")
        let row = UI.hbox(spacing: 14, [icon, text, chevron])
        let button = UI.button(content: row, classes: ["start-option"] + (prominent ? ["prominent"] : []), action: action)
        button.accessibleLabel("\(title). \(detail)")
        return button
    }
}
