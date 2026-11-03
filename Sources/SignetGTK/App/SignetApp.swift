import CAdwaita
import CWebKit
import Foundation

/// The GTK counterpart of upstream's `SignetApp.swift`: builds the model, owns the application
/// and its single window. libadwaita's `AdwApplication` is unique per user session through
/// D-Bus, so a second launch hands over to the running one, as `LSMultipleInstancesProhibited`
/// does on the Mac.
@MainActor
enum SignetApp {
    /// True when this process is the host for `SignetTests`. SwiftPM runs the tests in a runner
    /// of their own that never starts the app, so this is only kept for upstream's callers.
    static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// The app's model, as upstream builds it. Under a test host it is built on in-memory stores
    /// only (S24).
    static func makeModel(isTestHost: Bool = isTestHost) -> WalletViewModel {
        if isTestHost {
            return WalletViewModel(wallets: [], chain: MockChainService(), multisig: MockMultisigService(), walletStore: InMemoryWalletStore(), nodeProbe: { _ in throw URLError(.notConnectedToInternet) })
        }
        TaquitoBridge.shared.configureLog(at: TaquitoBridge.logFileURL)
        TaquitoBridge.shared.operationJournal = OperationJournal(directory: TezosClientStore.defaultDirectory)
        return WalletViewModel(
            chainFactory: { network in TaquitoChainService(network: network) },
            keyGenerator: KeyGenerator(),
            ledger: BridgeLedgerService(),
            keyImporter: BridgeKeyImporter(),
            multisig: BridgeMultisigService(),
            importSource: TezosClientStore.octezClientDirectory,
            directorySettings: WalletDirectorySettings(),
            storeFactory: { directory in
                (wallets: TezosClientStore(directory: directory), state: FileAppStateStore(directory: directory))
            },
            backupSettings: BackupSettings(),
            dappStorageFactory: { directory in OctezConnectStorage(directory: directory) },
            dappDiagnostics: DeveloperSettings.dappDiagnostics,
            startDApps: true,
            shieldedStoreFactory: { directory, chain -> any ShieldedWalletStore in
                guard let directory else { return InMemoryShieldedWalletStore() }
                return FileShieldedWalletStore(directory: directory, chain: chain)
            }
        )
    }

    private static var model: WalletViewModel?
    private static var window: Widget?

    static func run() -> Int32 {
        // Session-only keys live in memory (`SessionKeyStore`); a core dump would write that
        // memory to disk, so no core file is ever produced.
        var none = rlimit(rlim_cur: 0, rlim_max: 0)
        #if os(Linux)
        setrlimit(__rlimit_resource_t(RLIMIT_CORE.rawValue), &none)
        #else
        setrlimit(RLIMIT_CORE, &none)
        #endif

        MainLoop.attachMainQueue()
        // G_APPLICATION_HANDLES_OPEN: a raw value, since GLib 2.90 imports the flags as an option
        // set. The app opens signet:// links (`open` below); a link given to a second launch is
        // passed to the running one, as on the Mac.
        let app = Widget(adw_application_new("org.tezos.signet", GApplicationFlags(rawValue: 1 << 2))!)
        Signals.connect(app, "startup") {
            // WebKit takes the thread it is first set up on for the main thread, and the Buy
            // sheet's web view needs that to be GTK's. The bridge, made after startup, uses
            // JavaScriptCore (WebKit's engine) on a thread of its own, so WebKit is set up here
            // first, by making its default context (no web view: making and dropping one here
            // crashed FreeBSD's WebKitGTK at launch about one time in four).
            _ = webkit_web_context_get_default()
            Style.install()
            // The icon the package installs under the application id.
            gtk_window_set_default_icon_name("org.tezos.signet")
        }
        Signals.connect(app, "activate") { activate(app) }
        let open: @convention(c) (gpointer?, UnsafeMutablePointer<OpaquePointer?>?, gint, UnsafePointer<gchar>?, gpointer?) -> Void = { app, files, count, _, _ in
            var urls: [URL] = []
            for index in 0..<Int(max(count, 0)) {
                guard let file = files?[index], let uri = g_file_get_uri(file) else { continue }
                if let url = URL(string: String(cString: uri)) { urls.append(url) }
                g_free(uri)
            }
            MainActor.assumeIsolated { SignetApp.openURLs(urls, app: Widget(app!)) }
        }
        g_signal_connect_data(app.raw, "open", unsafeBitCast(open, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        return g_application_run(app.as(), CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// `.onOpenURL`: signet://?type=tzip10&data=<pairing code>, what a dApp's wallet list opens
    /// for desktop wallets. The window comes up first if this launch was only to open the link.
    private static func openURLs(_ urls: [URL], app: Widget) {
        activate(app)
        for url in urls { model?.handleIncomingURL(url) }
    }

    private static func activate(_ app: Widget) {
        if let window {
            gtk_window_present(window.as())
            return
        }
        let model = makeModel()
        self.model = model
        Appearance.stored.apply()
        let window = MainWindow.make(app: app, model: model)
        self.window = window
        gtk_window_present(window.as())
        Disclaimer.presentIfWanted(over: window, app: app)
    }
}
