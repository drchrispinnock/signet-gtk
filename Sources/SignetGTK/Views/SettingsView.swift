import CAdwaita
import Foundation

/// App settings: appearance, where the wallet files live, how they are backed up, and developer
/// switches. Nodes are edited in `NetworksSheet`. The GTK counterpart of upstream's
/// `Views/SettingsView.swift`, shown as a sheet over the window rather than a window of its own.
/// It has no Updates section: on Linux and the BSDs Signet is updated by whatever installed it,
/// not by Sparkle.
@MainActor
final class SettingsView: Sheet {
    private let appearancePicker = Widget(adw_toggle_group_new()!)
    private var disclaimerToggle: Widget!
    private let walletPath = UI.label(classes: ["address"], wrap: true, xalign: 1)
    private let backupPath = UI.label(classes: ["address"], wrap: true, xalign: 1)
    private var walletDefault: Widget!
    private var backupDefault: Widget!
    private var generationsRow: Widget!
    private let lastBackup = UI.label(classes: ["dim-label"], xalign: 1)
    private var walletSection: Widget!
    private var backupSection: Widget!
    private var diagnosticsToggle: Widget!
    private var diagnosticsNote: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 480)

        for option in Appearance.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, option.title)
            adw_toggle_set_name(toggle, option.rawValue)
            adw_toggle_group_add(appearancePicker.opaque, toggle)
        }
        adw_toggle_group_set_active_name(appearancePicker.opaque, Appearance.stored.rawValue)
        Signals.connect(appearancePicker, "notify::active-name") { [unowned self] in
            guard let name = adw_toggle_group_get_active_name(self.appearancePicker.opaque),
                  let choice = Appearance(rawValue: String(cString: name)) else { return }
            UserDefaults.standard.set(choice.rawValue, forKey: Appearance.key)
            choice.apply()
        }
        disclaimerToggle = Form.toggle("Show the disclaimer at launch", isOn: Disclaimer.isWanted) { [unowned self] in
            UserDefaults.standard.set(Form.isOn(self.disclaimerToggle), forKey: Disclaimer.key)
        }
        let appearance = Form.group([Form.labeled("Appearance", content: appearancePicker), disclaimerToggle])

        // Wallet directory.
        walletDefault = UI.button("Use Default") { [model] in
            if let fallback = model.defaultWalletDirectory { model.changeWalletDirectory(to: fallback) }
        }
        let walletButtons = UI.hbox(spacing: 8, [
            UI.button("Open Folder") { [unowned self] in self.model.walletDirectory.map { self.reveal($0) } },
            walletDefault,
            UI.button("Choose…") { [unowned self] in
                guard let directory = self.model.walletDirectory else { return }
                self.chooseFolder(title: "Choose Wallet Directory", from: directory) { [model] in model.changeWalletDirectory(to: $0) }
            },
        ]).align(h: GTK_ALIGN_END)
        walletSection = section(rows: [Form.stacked("Wallet directory", value: walletPath, below: [walletButtons])],
                                footer: "Wallet files are kept here in octez-client's format (public_key_hashs, public_keys, secret_keys). Choosing another directory switches to the wallets in it; nothing is moved or copied.")

        // Backups.
        backupDefault = UI.button("Use Default") { [model] in
            if let fallback = model.defaultBackupDirectory { model.setBackupDirectory(fallback) }
        }
        let backupButtons = UI.hbox(spacing: 8, [
            UI.button("Open Folder") { [unowned self] in self.model.backupDirectory.map { self.reveal($0) } },
            backupDefault,
            UI.button("Choose…") { [unowned self] in
                guard let directory = self.model.backupDirectory else { return }
                self.chooseFolder(title: "Choose Backup Folder", from: directory) { [model] in model.setBackupDirectory($0) }
            },
        ]).align(h: GTK_ALIGN_END)
        let range = BackupSettings.generationRange
        generationsRow = Widget(adw_spin_row_new_with_range(Double(range.lowerBound), Double(range.upperBound), 1)!)
        adw_preferences_row_set_title(generationsRow.as(), "Generations to keep")
        adw_spin_row_set_value(generationsRow.opaque, Double(model.backupGenerations))
        Signals.connect(generationsRow, "notify::value") { [unowned self] in
            let value = Int(adw_spin_row_get_value(self.generationsRow.opaque))
            if value != self.model.backupGenerations { self.model.setBackupGenerations(value) }
        }
        let backUpNow = UI.button("Back Up Now") { [model] in Task { await model.backUp(force: true) } }
        backupSection = section(rows: [
            Form.stacked("Backup folder", value: backupPath, below: [backupButtons]),
            generationsRow,
            Form.stacked("Last backup", value: lastBackup, below: [backUpNow.align(h: GTK_ALIGN_END)]),
        ], footer: "The wallet files are copied here on every launch and after any key is created or renamed. Automatic copies are skipped when nothing has changed; Back Up Now always writes one. Only the newest generations are kept.")

        // Developer.
        let armed = UserDefaults.standard.bool(forKey: DeveloperSettings.dappDiagnosticsKey)
        diagnosticsToggle = Form.toggle("Verbose dApp log on the next launch", isOn: armed) { [unowned self] in
            UserDefaults.standard.set(Form.isOn(self.diagnosticsToggle), forKey: DeveloperSettings.dappDiagnosticsKey)
        }
        diagnosticsNote = Form.note("Verbose dApp logging is on for this run; it switches itself off at the next launch.", style: "warning-text").row
        let developer = section(title: "Developer", rows: [diagnosticsToggle, diagnosticsNote],
                                footer: "The bridge log (\(UI.tilde(TaquitoBridge.logFileURL))) never contains keys, signatures or message contents. The verbose dApp log adds the relay SDK's own debugging output, which includes decrypted dApp traffic; it is armed for one launch only.")

        content.setChildren([Sheet.title("Settings"), appearance, walletSection, backupSection, developer])
        setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        trackers.append(Tracker { [unowned self] in self.update() })
    }

    private func section(title: String? = nil, rows: [Widget], footer: String) -> Widget {
        var children: [Widget] = []
        if let title { children.append(UI.label(title, classes: ["heading"])) }
        children.append(Form.group(rows))
        children.append(UI.label(footer, classes: ["dim-label", "caption"], wrap: true))
        return UI.vbox(spacing: 6, children)
    }

    private func update() {
        walletSection.isVisible = model.walletDirectory != nil
        if let directory = model.walletDirectory {
            UI.setText(walletPath, UI.tilde(directory))
            walletPath.tooltip(directory.path)
        }
        walletDefault.isSensitive = !model.isUsingDefaultWalletDirectory
        backupSection.isVisible = model.backupDirectory != nil
        if let directory = model.backupDirectory {
            UI.setText(backupPath, UI.tilde(directory))
            backupPath.tooltip(directory.path)
        }
        backupDefault.isSensitive = !model.isUsingDefaultBackupDirectory
        if Int(adw_spin_row_get_value(generationsRow.opaque)) != model.backupGenerations {
            adw_spin_row_set_value(generationsRow.opaque, Double(model.backupGenerations))
        }
        UI.setText(lastBackup, lastBackupDescription)
        diagnosticsNote.isVisible = model.dapps.diagnostics
    }

    private var lastBackupDescription: String {
        if let error = model.lastBackupError { return "Failed: \(error)" }
        guard let last = model.lastBackup else { return "Not yet" }
        let when = last.date.formatted(date: .abbreviated, time: .shortened)
        switch last.outcome {
        case .created: return "Saved \(when)"
        case .unchanged: return "Up to date (\(when))"
        case .nothingToBackUp: return "No wallet files yet"
        }
    }

    /// Opens the folder in the file manager ("Show in Finder" upstream).
    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        UI.open(url, from: content)
    }

    private final class Chosen {
        let onChoose: @MainActor (URL) -> Void
        init(_ onChoose: @escaping @MainActor (URL) -> Void) { self.onChoose = onChoose }
    }

    /// GTK's folder chooser (`NSOpenPanel` upstream).
    private func chooseFolder(title: String, from current: URL, onChoose: @escaping @MainActor (URL) -> Void) {
        let chooser = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(chooser, title)
        gtk_file_dialog_set_accept_label(chooser, "Use This Folder")
        let start = FileManager.default.fileExists(atPath: current.path) ? current : current.deletingLastPathComponent()
        let folder = g_file_new_for_path(start.path)
        gtk_file_dialog_set_initial_folder(chooser, folder)
        g_object_unref(UnsafeMutableRawPointer(folder))
        let window = gtk_widget_get_root(content.pointer).map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        let box = Unmanaged.passRetained(Chosen(onChoose)).toOpaque()
        gtk_file_dialog_select_folder(chooser, window, nil, { source, result, data in
            let chosen = Unmanaged<Chosen>.fromOpaque(data!).takeRetainedValue()
            defer { g_object_unref(source) }
            guard let file = gtk_file_dialog_select_folder_finish(OpaquePointer(source), result, nil) else { return }
            defer { g_object_unref(UnsafeMutableRawPointer(file)) }
            guard let path = g_file_get_path(file) else { return }
            let url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            g_free(path)
            MainActor.assumeIsolated { chosen.onChoose(url) }
        }, box)
    }
}
