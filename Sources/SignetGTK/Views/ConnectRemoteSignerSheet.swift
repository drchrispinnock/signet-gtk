import CAdwaita
import Foundation

/// Connect Remote Signer: an account whose key a remote signer holds (octez-signer, Signatory,
/// Russignol: anything speaking octez-signer's protocol). The user picks how the signer listens
/// (HTTP, HTTPS or TCP, with octez-signer's default ports), where, and which of its keys;
/// Signet asks the signer for that key's public key, derives the address from it and adds the
/// account only when the two agree. The GTK counterpart of upstream's
/// `Views/ConnectRemoteSignerSheet.swift`.
@MainActor
final class ConnectRemoteSignerSheet: Sheet {
    static let transports: [RemoteSignerLocator.Transport] = [.http, .https, .tcp]

    private var transport: RemoteSignerLocator.Transport = .tcp
    private var listedKeys: [Address]?
    private var isListing = false
    private var listNote: String?
    private var check: WalletViewModel.RemoteSignerCheck?
    private var checkError: String?
    private var isChecking = false
    private var isAdding = false
    /// The signer the running check is for (`.task(id: signer)`).
    private var checkedSigner: RemoteSignerLocator??
    private var checking: Task<Void, Never>?
    private var listing: Task<Void, Never>?

    private let transportToggles = Widget(adw_toggle_group_new()!)
    private var hostField: Widget!
    private var portField: Widget!
    private let hostNote: (row: Widget, label: Widget)
    private var keyField: Widget!
    private let keySuffix = UI.hbox(spacing: 0)
    private let listNoteRow: (row: Widget, label: Widget)
    private let keyNote: (row: Widget, label: Widget)
    private let checkBox = UI.vbox(spacing: 8)
    private let checkRow: Widget
    private var aliasField: Widget!
    private let aliasNote: (row: Widget, label: Widget)
    private let tcpNote: Widget
    private var addButton: Widget!

    init(model: WalletViewModel) {
        hostNote = Form.note("", icon: "dialog-warning-symbolic", style: "warning-text")
        listNoteRow = Form.note("")
        keyNote = Form.note("That is not a tz1 to tz5 address.", icon: "dialog-warning-symbolic", style: "warning-text")
        checkRow = Form.row(checkBox)
        aliasNote = Form.note("An account or address is already called that.", style: "error-text")
        tcpNote = UI.hbox(spacing: 8, [
            UI.image(icon: "channel-insecure-symbolic").align(v: GTK_ALIGN_START),
            UI.label("TCP is not encrypted. What Signet sends to sign is public anyway and every signature is checked against the key, but a signer reachable from the internet without authentication will sign for anyone who asks.", wrap: true).expand(h: true),
        ]).classes("dim-label")
        super.init(model: model, width: 560)

        for transport in Self.transports {
            let toggle = adw_toggle_new()!
            adw_toggle_set_label(toggle, transport.title)
            adw_toggle_set_name(toggle, transport.rawValue)
            adw_toggle_group_add(transportToggles.opaque, toggle)
        }
        adw_toggle_group_set_active_name(transportToggles.opaque, transport.rawValue)
        Signals.connect(transportToggles, "notify::active-name") { [unowned self] in
            guard let name = adw_toggle_group_get_active_name(self.transportToggles.opaque),
                  let new = RemoteSignerLocator.Transport(rawValue: String(cString: name)), new != self.transport else { return }
            self.transportChanged(from: self.transport, to: new)
        }
        hostField = Form.entry("Host", text: "localhost", onChange: { [unowned self] in self.endpointChanged() })
        portField = Form.entry("Port", text: String(RemoteSignerLocator.Transport.tcp.defaultPort!), onChange: { [unowned self] in self.endpointChanged() })
        let ports = "The usual ports are \(RemoteSignerLocator.Transport.http.defaultPort!) for HTTP, \(RemoteSignerLocator.Transport.https.defaultPort!) for HTTPS and \(RemoteSignerLocator.Transport.tcp.defaultPort!) for TCP (octez-signer's defaults). Use whatever port your signer is set to."

        keyField = Form.entry("Key (tz1…, tz2…, tz3… or tz4…)", onChange: { [unowned self] in self.update() })
        Form.addSuffix(keySuffix, to: keyField)
        aliasField = Form.entry("Name", onChange: { [unowned self] in self.update() },
                                onSubmit: { [unowned self] in if self.canAdd { self.add() } })

        content.setChildren([
            UI.hbox(spacing: 8, [UI.image(icon: "network-server-symbolic", pixelSize: 20), Sheet.title("Connect Remote Signer")]),
            UI.vbox(spacing: 6, [
                Form.group([Form.labeled("Connection", content: transportToggles), hostField, portField, hostNote.row]),
                UI.label(ports, classes: ["dim-label", "caption"], wrap: true),
            ]),
            Form.group([keyField, listNoteRow.row, keyNote.row, checkRow, aliasField, aliasNote.row]),
            tcpNote,
            UI.label("Signet keeps only the address and public key. Every operation is sent to the signer to sign, and its signature is checked against the account's key before anything is sent to the network. octez-client can use the account too.", classes: ["dim-label"], wrap: true),
        ])
        addButton = button("Add Account", role: .prominent, isDefault: true) { [unowned self] in self.add() }
        setButtons([cancelButton(), addButton])
        trackers.append(Tracker { [weak self] in
            guard let self else { return }
            _ = self.model.wallets
            self.update()
        })
    }

    // MARK: What was entered

    private var trimmedHost: String { Form.text(hostField).trimmingCharacters(in: .whitespaces) }
    private var portText: String { Form.text(portField) }
    private var port: Int? { Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var addressText: String { Form.text(keyField) }
    private var address: Address { Address(addressText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var alias: String { Form.text(aliasField) }

    /// Why the host cannot be used this way, if it cannot. Upstream: "… on this Mac or your
    /// local network."
    private var hostProblem: String? {
        guard !trimmedHost.isEmpty else { return nil }
        if trimmedHost.contains("/") || trimmedHost.contains("@") || trimmedHost.contains(" ") { return "Enter only the host name or IP address." }
        if transport == .http, !EndpointPolicy.isLocalOrPrivateHost(trimmedHost) {
            return "Plain HTTP is only for a signer on this computer or your local network. Use HTTPS or TCP for one elsewhere."
        }
        return nil
    }

    /// The signer as entered, for any key; `nil` until host and port make sense.
    private var endpoint: RemoteSignerLocator? {
        guard !trimmedHost.isEmpty, hostProblem == nil, let port else { return nil }
        return RemoteSignerLocator(transport: transport, host: trimmedHost, port: port, address: address)
    }

    private var signer: RemoteSignerLocator? { address.isImplicitAccount ? endpoint : nil }
    private var existing: Wallet? { model.wallets.first { $0.address == address } }
    private var aliasTaken: Bool { model.wallets.contains { $0.alias == alias.trimmingCharacters(in: .whitespaces) } }
    private var canAdd: Bool {
        guard let signer, let check, check.signer == signer, existing == nil, !isAdding else { return false }
        return !alias.trimmingCharacters(in: .whitespaces).isEmpty && !aliasTaken
    }

    // MARK: Changes

    /// Keep a port the user typed; follow the defaults otherwise.
    private func transportChanged(from old: RemoteSignerLocator.Transport, to new: RemoteSignerLocator.Transport) {
        transport = new
        if portText.isEmpty || Int(portText) == old.defaultPort { Form.setText(portField, new.defaultPort.map(String.init) ?? "") }
        endpointChanged()
    }

    /// A listing still waiting on the old signer is dropped too.
    private func endpointChanged() {
        listing?.cancel()
        isListing = false
        listedKeys = nil
        listNote = nil
        update()
    }

    private func update() {
        if let hostProblem {
            UI.setText(hostNote.label, hostProblem)
            hostNote.row.isVisible = true
        } else if port == nil, !portText.isEmpty {
            UI.setText(hostNote.label, "The port is a number from 1 to 65535.")
            hostNote.row.isVisible = true
        } else {
            hostNote.row.isVisible = false
        }

        if let listedKeys, !listedKeys.isEmpty {
            let menu = UI.popoverMenu("Keys", sections: [(heading: nil, items: listedKeys.map { key in
                (title: key.value, enabled: true, action: { @MainActor [unowned self] in Form.setText(self.keyField, key.value) })
            })])
            menu.classes("flat")
            keySuffix.setChildren([menu])
        } else {
            let list = UI.button("List Keys", classes: ["flat"]) { [unowned self] in self.listKeys() }
            list.isSensitive = endpoint != nil && !isListing
            keySuffix.setChildren([list])
        }
        UI.setText(listNoteRow.label, listNote ?? "")
        listNoteRow.row.isVisible = listNote != nil
        keyNote.row.isVisible = !addressText.isEmpty && !address.isImplicitAccount
        aliasNote.row.isVisible = aliasTaken

        if checkedSigner != .some(signer) {
            checkedSigner = .some(signer)
            startCheck()
        }
        updateCheckRow()

        tcpNote.isVisible = transport == .tcp && endpoint.map { !EndpointPolicy.isLocalOrPrivateHost($0.host) } == true
        addButton.isSensitive = canAdd
    }

    private func updateCheckRow() {
        var rows: [Widget] = []
        if let existing, address.isImplicitAccount {
            rows.append(UI.hbox(spacing: 6, [UI.image(icon: "object-select-symbolic"), UI.label("Already in your list as “\(existing.alias)”.", wrap: true)]).classes("dim-label"))
        } else if isChecking {
            rows.append(UI.hbox(spacing: 8, [Widget(adw_spinner_new()!).size(width: 16, height: 16), UI.label("Asking the signer…", classes: ["dim-label"])]))
        } else if let check, check.signer == signer {
            let scheme = check.signer.address.scheme?.displayName ?? ""
            let address = UI.label(check.signer.address.value, classes: ["address"], wrap: true)
            gtk_label_set_selectable(address.opaque, 1)
            let holds = UI.hbox(spacing: 4, [UI.image(icon: "emblem-ok-symbolic", pixelSize: 12), UI.label("The signer holds this key (\(scheme)).", classes: ["caption"])]).classes("success")
            rows.append(UI.hbox(spacing: 10, [AccountAvatarView(address: check.signer.address, size: 32).root, UI.vbox(spacing: 2, [address, holds]).expand(h: true)]))
            if !check.acceptsUnauthenticated {
                rows.append(UI.hbox(spacing: 8, [
                    UI.image(icon: "dialog-warning-symbolic").align(v: GTK_ALIGN_START),
                    UI.label("This signer requires authenticated requests, which Signet cannot make yet, so it will refuse to sign. Turn authentication off in the signer (octez-signer: --require-authentication) and keep it reachable only by you, for example through a tunnel.", wrap: true).expand(h: true),
                ]).classes("warning-text"))
            }
        } else if let checkError {
            rows.append(UI.hbox(spacing: 8, [
                UI.image(icon: "dialog-error-symbolic").align(v: GTK_ALIGN_START),
                UI.label(checkError, wrap: true).expand(h: true),
            ]).classes("error-text"))
        }
        checkBox.setChildren(rows)
        checkRow.isVisible = !rows.isEmpty
    }

    // MARK: Asking the signer

    /// `.task(id: signer) { await checkSigner() }`.
    private func startCheck() {
        checking?.cancel()
        check = nil
        checkError = nil
        isChecking = false
        guard let signer, existing == nil else { return }
        checking = Task { [weak self, model] in
            // Wait for typing to settle before asking.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.isChecking = true
            self.updateCheckRow()
            do {
                let result = try await model.checkRemoteSigner(signer)
                guard !Task.isCancelled else { return }
                self.check = result
                if self.alias.isEmpty { Form.setText(self.aliasField, "Remote \(signer.address.shortened(prefix: 6, suffix: 4))") }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.checkError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self.isChecking = false
            self.update()
        }
    }

    private func listKeys() {
        guard let endpoint else { return }
        isListing = true
        listNote = nil
        update()
        listing = Task { [weak self, model] in
            let note: String?
            var keys: [Address]?
            do {
                keys = try await model.remoteSignerKeys(at: endpoint)
                note = keys!.isEmpty ? "The signer lists no keys." : nil
            } catch RemoteSignerError.notFound, RemoteSignerError.closed {
                note = "This signer does not list its keys. Enter the key's address; the signer's own configuration or key list shows it."
            } catch {
                note = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.isListing = false
            // The signer's address may have been changed meanwhile.
            guard self.endpoint.map({ ($0.transport, $0.host, $0.port) == (endpoint.transport, endpoint.host, endpoint.port) }) == true else {
                self.update()
                return
            }
            self.listedKeys = keys
            self.listNote = note
            if let keys, keys.count == 1, self.addressText.isEmpty { Form.setText(self.keyField, keys[0].value) }
            self.update()
        }
    }

    private func add() {
        guard canAdd, let signer else { return }
        isAdding = true
        setError(nil)
        update()
        let alias = alias
        Task {
            defer { isAdding = false; update() }
            do {
                try await model.connectRemoteSigner(alias: alias, signer: signer)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() {
        checking?.cancel()
        listing?.cancel()
    }
}
