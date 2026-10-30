import CAdwaita
import Foundation

/// The launch warning. Shown once per launch until the user turns it off in Settings. The text
/// and the preference key are upstream's (`Views/DisclaimerAlert.swift`).
enum Disclaimer {
    static let key = "showsDisclaimer"
    static let title = "⚠️ Signet - Warning"
    static let message = "Signet is very new software and should be used with care. Make sure you protect your keys with a password or use a Ledger.\n\nYou can turn off this warning in the Settings."

    /// On by default, as `@AppStorage(Disclaimer.key) var showsDisclaimer = true` is upstream.
    static var isWanted: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Presents the warning over the window. OK carries on; Exit quits the app.
    @MainActor
    static func presentIfWanted(over window: Widget, app: Widget) {
        guard isWanted else { return }
        let dialog = Widget(adw_alert_dialog_new(title, message)!)
        adw_alert_dialog_add_response(dialog.as(), "exit", "Exit")
        adw_alert_dialog_add_response(dialog.as(), "ok", "OK")
        adw_alert_dialog_set_response_appearance(dialog.as(), "exit", ADW_RESPONSE_DESTRUCTIVE)
        adw_alert_dialog_set_default_response(dialog.as(), "ok")
        adw_alert_dialog_set_close_response(dialog.as(), "ok")
        Signals.connect(dialog, "response::exit") { g_application_quit(app.as()) }
        adw_dialog_present(dialog.as(), window.pointer)
    }
}
