import CAdwaita
import Foundation

/// Adds a key that lives on a Ledger: finds the device, checks the Tezos app is open, derives
/// the address for the chosen curve and account, and has the user approve it on the device.
/// The GTK counterpart of upstream's `Views/ConnectLedgerSheet.swift`.
@MainActor
final class ConnectLedgerSheet: Sheet {
    private var devices: [LedgerDevice] = []
    private var appInfo: LedgerAppInfo?
    private var appProblem: String?
    private var preview: Address?
    private var previewTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var isAdding = false

    private let deviceStatus = UI.hbox(spacing: 8)
    private var aliasField: Widget!
    private var curvePicker: Widget!
    private var accountRow: Widget!
    private var pathValue: Widget!
    private let addressBox = UI.vbox(spacing: 2)
    private var addButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 520)
        aliasField = Form.entry("Name", text: model.suggestedAlias(base: "Ledger"), onChange: { [unowned self] in self.update() })
        curvePicker = Form.picker("Key type", options: LedgerCurve.allCases.map(\.displayName), selected: 0) { [unowned self] in self.keyChanged() }
        accountRow = Widget(adw_spin_row_new_with_range(0, 100, 1)!)
        Signals.connect(accountRow, "notify::value") { [unowned self] in self.keyChanged() }
        let path = Form.labeled("Path", value: "", monospaced: true)
        pathValue = path.value
        let form = Form.group([
            Form.labeled("Device", content: deviceStatus), aliasField, curvePicker, accountRow, path.row,
            Form.labeled("Address", content: addressBox),
            Form.note("Press Add and the Ledger will show this address; approve it there to finish. The key stays on the device, which asks you to approve every operation. The entry is written to ~/.signet as a ledger:// alias octez-client can use too.").row,
        ])
        content.setChildren([Sheet.title("Connect Ledger"), form])
        addButton = button("Add", role: .prominent, isDefault: true) { [unowned self] in self.add() }
        focus(aliasField)
        updateKeyRows()
        update()
        // `.task { await pollDevices() }`.
        pollTask = Task { [weak self] in await self?.pollDevices() }
    }

    private var device: LedgerDevice? { devices.first }
    private var ready: Bool { device != nil && appInfo?.isWallet == true }
    private var trimmedAlias: String { Form.text(aliasField).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var curve: LedgerCurve { LedgerCurve.allCases[max(0, Form.selected(curvePicker))] }
    private var account: Int { Int(adw_spin_row_get_value(accountRow.opaque)) }
    private var key: LedgerKey { LedgerKey(rootID: "", curve: curve, account: account) }
    private var existing: Wallet? { preview.flatMap { address in model.wallets.first { $0.address == address } } }
    private var canAdd: Bool { ready && !trimmedAlias.isEmpty && !isAdding && existing == nil }

    private func keyChanged() {
        updateKeyRows()
        refreshPreview()
    }

    private func updateKeyRows() {
        adw_preferences_row_set_title(accountRow.as(), "Account \(account)")
        UI.setText(pathValue, key.fullPath)
    }

    private func update() {
        updateDeviceStatus()
        if let preview {
            let address = UI.label(preview.value, classes: ["address"], xalign: 1)
            gtk_label_set_selectable(address.opaque, 1)
            var lines = [address]
            if let existing { lines.append(UI.label("Already in your list as “\(existing.alias)”", classes: ["warning-text", "caption"], xalign: 1)) }
            addressBox.setChildren(lines)
        } else if ready {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            addressBox.setChildren([spinner.align(h: GTK_ALIGN_END)])
        } else {
            addressBox.setChildren([UI.label("—", classes: ["dim-label"], xalign: 1)])
        }
        setBusy(isAdding ? "Approve the address on your Ledger…" : nil)
        canClose = !isAdding
        let cancel = cancelButton()
        cancel.isSensitive = !isAdding
        addButton.isSensitive = canAdd
        setButtons([cancel, addButton])
    }

    private func updateDeviceStatus() {
        let light = UI.vbox().classes("node-light").align(v: GTK_ALIGN_CENTER)
        guard let device else {
            light.classes("red")
            deviceStatus.setChildren([light, UI.label("No Ledger found. Plug it in, unlock it and open the Tezos app.", classes: ["dim-label"], wrap: true, xalign: 1)])
            return
        }
        light.classes(ready ? "green" : "yellow")
        var lines = [UI.label(device.model, xalign: 1)]
        if let appInfo {
            lines.append(UI.label(appInfo.isWallet ? "Tezos Wallet \(appInfo.version)" : "Tezos Baking app \(appInfo.version): open the Tezos Wallet app instead",
                                  classes: ["caption", appInfo.isWallet ? "dim-label" : "warning-text"], wrap: true, xalign: 1))
        } else if let appProblem {
            lines.append(UI.label(appProblem, classes: ["caption", "warning-text"], wrap: true, xalign: 1))
        } else {
            lines.append(UI.label("Checking…", classes: ["caption", "dim-label"], xalign: 1))
        }
        deviceStatus.setChildren([light, UI.vbox(spacing: 2, lines)])
    }

    /// Watches for the device and the app while the sheet is up.
    private func pollDevices() async {
        while !Task.isCancelled {
            let found = await model.ledger.devices()
            guard !Task.isCancelled else { return }
            let changed = found != devices
            devices = found
            if let device {
                if changed || appInfo == nil {
                    do {
                        let info = try await model.ledger.appInfo(deviceID: device.id)
                        let becameReady = info != appInfo
                        appInfo = info
                        appProblem = nil
                        if becameReady { refreshPreview() }
                    } catch {
                        appInfo = nil
                        appProblem = (error as? ChainError)?.localizedDescription ?? "Open the Tezos app on the Ledger."
                        preview = nil
                    }
                }
            } else {
                appInfo = nil
                appProblem = nil
                preview = nil
            }
            update()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func refreshPreview() {
        previewTask?.cancel()
        preview = nil
        update()
        guard let device, ready, !isAdding else { return }
        let key = key
        previewTask = Task {
            let result = try? await model.ledger.address(deviceID: device.id, key: key, prompt: false)
            guard !Task.isCancelled else { return }
            preview = result?.address
            update()
        }
    }

    private func add() {
        guard let device, canAdd else { return }
        setError(nil)
        isAdding = true
        update()
        let (alias, curve, account) = (trimmedAlias, curve, account)
        Task {
            defer { isAdding = false; update() }
            do {
                try await model.connectLedger(alias: alias, deviceID: device.id, curve: curve, account: account)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() {
        pollTask?.cancel()
        previewTask?.cancel()
    }
}
