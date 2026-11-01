import CAdwaita
import Foundation

/// Pair with a dApp by pasting its Octez Connect code, and manage existing connections. The GTK
/// counterpart of upstream's `Views/ConnectDAppSheet.swift`.
@MainActor
final class ConnectDAppSheet: Sheet {
    private var isPairing = false
    private var message: String?
    private var isError = false
    private let relayStatus = UI.hbox(spacing: 6)
    private let relayError = UI.vbox(spacing: 6)
    private var codeField: Widget!
    private var pairButton: Widget!
    private let pairingSpinner = Widget(gtk_spinner_new()!)
    private let connected = Form.group([])
    private let pairingStatus = UI.label(wrap: true)
    private let messageLabel = UI.label(wrap: true)

    init(model: WalletViewModel) {
        super.init(model: model, width: 520)
        // Masked like a password: whoever holds the code can pair their own wallet with that dApp
        // session, so it should not sit readable on screen.
        codeField = Form.password("Pairing code (paste the code from the dApp)", onChange: { [unowned self] in self.update() },
                                  onSubmit: { [unowned self] in if self.canPair { self.pair() } })
        codeField.classes("monospace")
        pairButton = UI.button("Pair", classes: ["suggested-action"]) { [unowned self] in self.pair() }
        let pairRow = Form.row(UI.hbox(spacing: 8, [pairingSpinner, UI.hspacer(), pairButton]))
        let pairing = Form.group([
            codeField,
            Form.note("In the dApp choose Octez Connect (or Beacon), then “Pair wallet on another device” and copy the code. Signet connects over the Tezos relay; the dApp can be in any browser.").row,
            pairRow,
        ])
        let title = UI.hbox(spacing: 8, [Sheet.title("Connect to a dApp").expand(h: true), relayStatus.align(v: GTK_ALIGN_CENTER)])
        content.setChildren([
            title, relayError, pairing,
            UI.vbox(spacing: 6, [UI.label("Connected dApps", classes: ["heading"]), connected]),
            pairingStatus, messageLabel,
        ])
        setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        focus(codeField)
        trackers.append(Tracker { [unowned self] in self.update() })
        trackers.append(Tracker { [unowned self] in
            // `.onChange(of: model.pendingPairingCode)`.
            if self.model.pendingPairingCode != nil { self.takePendingCode() }
        })
        trackers.append(Tracker { [unowned self] in
            // Only one sheet can be up at a time: step aside as soon as the dApp's first request
            // arrives, so the approval sheet can show without the user having to close this one.
            if self.model.dapps.current != nil { Task { @MainActor in self.dismiss() } }
        })
        Task { [model] in await model.dapps.reloadPermissions() }
    }

    private var dapps: DAppConnectionManager { model.dapps }
    private var code: String { Form.text(codeField) }
    private var canPair: Bool { !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPairing }

    private func update() {
        let light = UI.vbox().classes("node-light", dapps.isStarted ? "green" : (dapps.lastError == nil ? "grey" : "red")).align(v: GTK_ALIGN_CENTER)
        relayStatus.setChildren([light, UI.label(dapps.isStarted ? "Octez Connect running" : (dapps.lastError == nil ? "Starting…" : "Octez Connect failed"), classes: ["dim-label", "caption"])])
        relayStatus.tooltip(dapps.lastError ?? "Connected to the Tezos relay")
        if let error = dapps.lastError, !dapps.isStarted {
            relayError.setChildren([UI.label(error, classes: ["error-text"], wrap: true),
                                    UI.button("Try again") { [dapps] in Task { await dapps.restart() } }.align(h: GTK_ALIGN_START)])
            relayError.isVisible = true
        } else {
            relayError.isVisible = false
        }

        pairButton.isSensitive = canPair
        pairingSpinner.isVisible = isPairing
        isPairing ? gtk_spinner_start(pairingSpinner.opaque) : gtk_spinner_stop(pairingSpinner.opaque)

        if dapps.permissions.isEmpty {
            Form.setRows(connected, [Form.note("None yet.").row])
        } else {
            var rows = dapps.permissions.map { permission in
                Form.row(UI.hbox(spacing: 10, [
                    DAppIconView.make(url: permission.appIcon, size: 28),
                    UI.vbox(spacing: 2, [UI.label(permission.appName),
                                         UI.label("\(walletName(for: permission.address)) · \(permission.networkType) · \(permission.scopes.joined(separator: ", "))", classes: ["dim-label", "caption"], wrap: true)]).expand(h: true),
                    UI.button("Disconnect") { [dapps] in Task { await dapps.disconnect(permission) } }.align(v: GTK_ALIGN_CENTER),
                ]))
            }
            rows.append(Form.row(UI.button("Disconnect all", classes: ["destructive-action"]) { [dapps] in Task { await dapps.disconnectAll() } }.align(h: GTK_ALIGN_START)))
            Form.setRows(connected, rows)
        }

        switch dapps.pairing {
        case .waiting(let name): show(pairingStatus, "Pairing with \(name)… waiting for the dApp to answer over the relay.", style: "dim-label")
        case .paired(let name): show(pairingStatus, "Paired with \(name). It will now ask for permission; approve it in the next window.", style: "success-icon")
        case .failed(let why): show(pairingStatus, why, style: "error-text")
        case .idle: pairingStatus.isVisible = false
        }
        if let message { show(messageLabel, message, style: isError ? "error-text" : "success-icon") } else { messageLabel.isVisible = false }
    }

    private func show(_ label: Widget, _ text: String, style: String) {
        UI.setText(label, text)
        for name in ["dim-label", "success-icon", "error-text"] { label.setClass(name, name == style) }
        label.isVisible = true
    }

    private func walletName(for address: String) -> String {
        model.wallets.first { $0.address.value == address }?.alias ?? Address(address).shortened()
    }

    /// A code that arrived through a signet:// link is pasted and paired automatically.
    private func takePendingCode() {
        guard let pending = model.pendingPairingCode else { return }
        model.pendingPairingCode = nil
        Form.setText(codeField, pending)
        pair()
    }

    private func pair() {
        isPairing = true
        message = nil
        update()
        let code = code
        Task {
            defer { isPairing = false; update() }
            do {
                _ = try await dapps.pair(code: code)
                isError = false
                message = nil
                Form.clear(codeField)
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }

    override func closed() { Form.clear(codeField) }
}

/// dApp icon or a generic placeholder.
@MainActor
enum DAppIconView {
    static func make(url: URL?, size: Int32 = 44) -> Widget {
        RemoteImage.make(urls: url.map { [$0] } ?? [], size: size, round: false) {
            let globe = UI.image(icon: "web-browser-symbolic", pixelSize: size / 2).classes("dim-label")
            globe.align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER).expand(h: true, v: true)
            return UI.vbox(spacing: 0, [globe]).size(width: size, height: size).classes("dapp-icon-placeholder")
        }.classes("dapp-icon")
    }
}
