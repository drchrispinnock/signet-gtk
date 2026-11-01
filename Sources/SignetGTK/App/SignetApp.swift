import CAdwaita
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
        let app = Widget(adw_application_new("org.tezos.signet", G_APPLICATION_DEFAULT_FLAGS)!)
        Signals.connect(app, "startup") {
            Style.install()
            // The icon the package installs under the application id.
            gtk_window_set_default_icon_name("org.tezos.signet")
        }
        Signals.connect(app, "activate") { activate(app) }
        return g_application_run(app.as(), CommandLine.argc, CommandLine.unsafeArgv)
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
