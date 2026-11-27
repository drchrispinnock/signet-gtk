import CAdwaita
import Foundation

/// The alert of upstream's `DomainReminderService`, which shows an `NSAlert` as a sheet on the
/// main window on the Mac and leaves it to the port elsewhere (`freeMainWindow`, `present`).
/// Here it is an `AdwAlertDialog` on the window: Renew… (or Open Tezos Domains) opens the name
/// on Tezos Domains in the browser, OK closes it.
extension DomainReminderService {
    /// Waits, checking every few seconds, until Signet's window is up with no sheet or alert on
    /// it, so the reminder never lands over a half-finished operation. `false` if the task is
    /// cancelled first.
    static func freeMainWindow() async -> Bool {
        while !Task.isCancelled {
            if let window = SignetApp.current?.window,
               gtk_widget_get_visible(window.pointer) != 0,
               adw_application_window_get_visible_dialog(window.as()) == nil {
                return true
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// Shows `alert` on the window and waits for it to be answered. A test from Settings goes on
    /// top of the Settings sheet (`onTop`); libadwaita stacks dialogs on the window either way.
    static func present(_ alert: Alert, onTop: Bool) async {
        guard let window = SignetApp.current?.window else { return }
        let dialog = Widget(adw_alert_dialog_new(alert.title, alert.message)!)
        adw_alert_dialog_add_response(dialog.as(), "open", alert.firstButton)
        adw_alert_dialog_add_response(dialog.as(), "ok", "OK")
        adw_alert_dialog_set_default_response(dialog.as(), "ok")
        adw_alert_dialog_set_close_response(dialog.as(), "ok")
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            for (response, opens) in [("open", true), ("ok", false)] {
                Signals.connect(dialog, "response::\(response)") {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: opens)
                }
            }
            adw_dialog_present(dialog.as(), window.pointer)
        }
        if opened, let url = alert.url { UI.open(url, from: window) }
    }
}

/// Upstream's `SignetApp.checkDomainReminders` and the `.task` that runs it: at launch, then
/// once a day while Signet runs, the names the user's accounts own are looked up, those due
/// soon are listed on the dashboard (`model.expiringDomains`) and any reminder now due goes up
/// as an alert. Nothing is scheduled with the system, as on the Mac and Windows.
@MainActor
enum DomainReminderSchedule {
    private static var daily: Task<Void, Never>?

    static func start(model: WalletViewModel) {
        guard !SignetApp.isTestHost, daily == nil else { return }
        daily = Task {
            while !Task.isCancelled {
                await checkNow(model: model)
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    /// Checks again now (the setting was changed).
    static func check(model: WalletViewModel) {
        Task { await checkNow(model: model) }
    }

    private static func checkNow(model: WalletViewModel) async {
        let service = DomainReminderService.shared
        guard DomainReminderSettings.isOn() else { model.expiringDomains = []; return }
        guard let names = await model.ownedDomainNamesForReminders() else { return }
        let now = Date()
        model.expiringDomains = names.filter { DomainReminders.isDueSoon($0.expires, now: now) }.sorted { $0.expires < $1.expires }
        await service.deliverDue(names, now: now)
    }
}
