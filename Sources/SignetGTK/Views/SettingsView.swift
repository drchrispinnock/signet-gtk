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
    private var nftToggle: Widget!
    private var passwordMinutesRow: Widget!
    private var remindersToggle: Widget!
    private let testReminderNote = UI.label(classes: ["dim-label"], wrap: true)
    private var testReminderLine: Widget!

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
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
            choice.apply()
        }
        disclaimerToggle = Form.toggle("Show the disclaimer at launch", isOn: Disclaimer.isWanted) { [unowned self] in
            UserDefaults.standard.set(Form.isOn(self.disclaimerToggle), forKey: Disclaimer.key)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
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

        // Passwords: how long a wallet password, once typed and found to be right, is remembered.
        let minutes = UserDefaults.standard.integer(forKey: PasswordCacheSettings.key)
        let minutesRange = PasswordCacheSettings.range
        passwordMinutesRow = Widget(adw_spin_row_new_with_range(Double(minutesRange.lowerBound), Double(minutesRange.upperBound), 1)!)
        adw_preferences_row_set_title(passwordMinutesRow.as(), "Remember passwords (minutes)")
        adw_spin_row_set_value(passwordMinutesRow.opaque, Double(min(max(minutes, minutesRange.lowerBound), minutesRange.upperBound)))
        let passwordNote = Form.note(Self.passwordNote(minutes))
        Signals.connect(passwordMinutesRow, "notify::value") { [unowned self] in
            let value = Int(adw_spin_row_get_value(self.passwordMinutesRow.opaque))
            guard value != UserDefaults.standard.integer(forKey: PasswordCacheSettings.key) else { return }
            UserDefaults.standard.set(value, forKey: PasswordCacheSettings.key)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
            UI.setText(passwordNote.label, Self.passwordNote(value))
            self.model.forgetRememberedPassphrases()
        }
        let forgetPasswords = UI.button("Forget remembered passwords") { [model] in model.forgetRememberedPassphrases() }
        let passwords = UI.vbox(spacing: 6, [UI.label("Passwords", classes: ["heading"]),
                                             Form.group([passwordMinutesRow, passwordNote.row, Form.row(forgetPasswords.align(h: GTK_ALIGN_START))])])

        // Notifications: Tezos Domains expiry reminders.
        let remindersOn = DomainReminderSettings.isOn()
        let remindersNote = Form.note(Self.remindersNote(remindersOn))
        testReminderLine = UI.hbox(spacing: 12, [
            UI.button("Show a test reminder") { [unowned self] in Task { await self.sendTestReminder() } },
            testReminderNote.expand(h: true),
        ])
        testReminderLine.isVisible = remindersOn
        remindersToggle = Form.toggle("Remind me before my Tezos Domains names expire", isOn: remindersOn) { [unowned self] in
            let on = Form.isOn(self.remindersToggle)
            UserDefaults.standard.set(on, forKey: DomainReminderSettings.key)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
            UI.setText(remindersNote.label, Self.remindersNote(on))
            self.testReminderLine.isVisible = on
            DomainReminderSchedule.check(model: self.model)   // `.onChange(of: domainRemindersOn)` upstream
        }
        let notifications = UI.vbox(spacing: 6, [UI.label("Notifications", classes: ["heading"]),
                                                 Form.group([remindersToggle, remindersNote.row, Form.row(testReminderLine)])])

        // NFTs.
        let arranges = NFTDownloadSettings.arrangesByAddress()
        let nftNote = Form.note(Self.nftNote(arranges))
        nftToggle = Form.toggle("Arrange NFTs by address", isOn: arranges) { [unowned self] in
            let on = Form.isOn(self.nftToggle)
            UserDefaults.standard.set(on, forKey: NFTDownloadSettings.arrangeByAddressKey)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
            UI.setText(nftNote.label, Self.nftNote(on))
        }
        let nfts = UI.vbox(spacing: 6, [UI.label("NFTs", classes: ["heading"]), Form.group([nftToggle, nftNote.row])])

        // Experimental Features: each says what it changes.
        let experimental = UI.vbox(spacing: 6, [UI.label("Experimental Features", classes: ["heading"]), Self.experimentalGroup()])

        // Developer.
        let armed = UserDefaults.standard.bool(forKey: DeveloperSettings.dappDiagnosticsKey)
        diagnosticsToggle = Form.toggle("Verbose dApp log on the next launch", isOn: armed) { [unowned self] in
            UserDefaults.standard.set(Form.isOn(self.diagnosticsToggle), forKey: DeveloperSettings.dappDiagnosticsKey)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
        }
        diagnosticsNote = Form.note("Verbose dApp logging is on for this run; it switches itself off at the next launch.", style: "warning-text").row
        let developer = section(title: "Developer", rows: [diagnosticsToggle, diagnosticsNote],
                                footer: "The bridge log (\(UI.tilde(TaquitoBridge.logFileURL))) never contains keys, signatures or message contents. The verbose dApp log adds the relay SDK's own debugging output, which includes decrypted dApp traffic; it is armed for one launch only.")

        content.setChildren([Sheet.title("Settings"), appearance, walletSection, backupSection, passwords, notifications, nfts, experimental, developer])
        setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        trackers.append(Tracker { [unowned self] in self.update() })
    }

    private static func nftNote(_ arrangesByAddress: Bool) -> String {
        arrangesByAddress
            ? "Downloaded artwork goes into a folder named after the account's address, inside the wallet directory's nfts folder."
            : "Downloaded artwork from every account goes into the wallet directory's nfts folder together."
    }

    private static func passwordNote(_ minutes: Int) -> String {
        minutes == 0
            ? "Every operation from an encrypted account asks for its password."
            : "Once you type an account's password and it opens the key, Signet keeps it in memory for \(minutes) minute\(minutes == 1 ? "" : "s") and does not ask again. It is never written to disk, and it is forgotten when the time is up, when the computer sleeps or locks, or when Signet quits. Exporting a key and forgetting an account always ask."
    }

    private static func remindersNote(_ on: Bool) -> String {
        on
            ? "Signet reminds you 2 months, 1 month, 2 weeks and 1 week before a name one of your accounts owns expires, then every day for the last week. It checks when it starts and once a day while it runs: a reminder that is due appears as an alert, with Renew to open the name on Tezos Domains, and the name stays on the dashboard until it is renewed. Nothing reaches you while Signet is closed."
            : "No reminders about Tezos Domains names."
    }

    private func sendTestReminder() async {
        UI.setText(testReminderNote, "Looking up your names…")
        guard let names = await model.ownedDomainNamesForReminders() else { UI.setText(testReminderNote, "Tezos Domains could not be read."); return }
        guard !names.isEmpty else { UI.setText(testReminderNote, "None of your accounts owns a Tezos Domains name."); return }
        UI.setText(testReminderNote, "")
        if !(await DomainReminderService.shared.showTest(names)) { UI.setText(testReminderNote, "None of your names is still current.") }
    }

    /// Layer 2 branding, layer marks and consolidated balances (`Experimental`).
    private static func experimentalGroup() -> Widget {
        let settings = Experimental.shared
        let brandingNote = Form.note(brandingNote(settings.branding))
        let brandings = Layer2Branding.allCases
        let brandingLogo = UI.hbox(spacing: 0)
        func showLogo(_ branding: Layer2Branding) {
            brandingLogo.setChildren(UI.resourceImage(branding.logoFile.name, branding.logoFile.ext, pixelSize: 16).map { [$0] } ?? [])
        }
        showLogo(settings.branding)
        var brandingPicker: Widget!
        brandingPicker = Form.picker("Layer 2 branding", options: brandings.map(\.name), selected: brandings.firstIndex(of: settings.branding) ?? 0) {
            let index = Form.selected(brandingPicker)
            guard brandings.indices.contains(index) else { return }
            settings.set(branding: brandings[index])
            showLogo(brandings[index])
            UI.setText(brandingNote.label, Self.brandingNote(brandings[index]))
        }
        adw_action_row_add_prefix(brandingPicker.as(), brandingLogo.align(v: GTK_ALIGN_CENTER).pointer)

        let marksNote = Form.note(marksNote(settings.marks))
        let marksPicker = Widget(adw_toggle_group_new()!)
        for marks in LayerMarks.allCases {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, marks.title)
            adw_toggle_set_name(toggle, marks.rawValue)
            adw_toggle_group_add(marksPicker.opaque, toggle)
        }
        adw_toggle_group_set_active_name(marksPicker.opaque, settings.marks.rawValue)
        Signals.connect(marksPicker, "notify::active-name") {
            guard let name = adw_toggle_group_get_active_name(marksPicker.opaque),
                  let marks = LayerMarks(rawValue: String(cString: name)) else { return }
            settings.set(marks: marks)
            UI.setText(marksNote.label, Self.marksNote(marks))
        }

        let consolidatedNote = Form.note(consolidatedNote(settings.consolidates))
        var consolidatedToggle: Widget!
        consolidatedToggle = Form.toggle("Consolidated balances", isOn: settings.consolidates) {
            let on = Form.isOn(consolidatedToggle)
            settings.set(consolidates: on)
            UI.setText(consolidatedNote.label, Self.consolidatedNote(on))
        }
        // The notes name the Layer 2 as the branding now says.
        let group = Form.group([brandingPicker, brandingNote.row, Form.labeled("Layer marks", content: marksPicker), marksNote.row,
                                consolidatedToggle, consolidatedNote.row])
        group.retain(Tracker {
            _ = settings.branding
            UI.setText(marksNote.label, Self.marksNote(settings.marks))
            UI.setText(consolidatedNote.label, Self.consolidatedNote(settings.consolidates))
        }, key: "signet-experimental")
        return group
    }

    private static func brandingNote(_ branding: Layer2Branding) -> String {
        branding == .tezosX
            ? "The Layer 2 is called Tezos X throughout Signet and shown with the Tezos X logo. Only the name and logo change: nodes, contracts and accounts are the same."
            : "The Layer 2 is called Etherlink, with Etherlink's logo."
    }

    private static func marksNote(_ marks: LayerMarks) -> String {
        marks == .logos
            ? "The Activity, Assets, NFTs and Domains tabs mark Tezos and \(Brand.l2) with their small logos."
            : "The Activity, Assets, NFTs and Domains tabs mark Tezos and \(Brand.l2) as L1 and L2."
    }

    private static func consolidatedNote(_ on: Bool) -> String {
        on
            ? "The dashboard shows one tez balance: everything the account holds on Tezos, on \(Brand.l2) and shielded. Expand it to see spendable, staked, \(Brand.l2) and shielded separately."
            : "Tez, \(Brand.l2) and shielded balances each have their own row."
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
