import CAdwaita
import Foundation

/// Scan QR code: reads a code with the camera, from an image on the clipboard or from an image
/// file, and hands it to the sheet that deals with it. A dApp pairing code goes to dApps, a
/// secret key or recovery phrase to Import account, and an address or public key is shown here
/// with the choice of adding it to the address book or sending to it. Nothing is acted on
/// without that next sheet, and what was scanned is never displayed unless it is an address.
/// The GTK counterpart of upstream's `Views/ScanQRSheet.swift`; the camera is zbar's
/// (`QRCaptureSession`), and where macOS asks for permission, Linux either opens the device
/// node or does not.
@MainActor
final class ScanQRSheet: Sheet {
    private enum CameraState: Equatable { case starting, running, failed(String), missing }

    /// An address the scan found, waiting for the user to say what to do with it.
    private struct Found: Equatable {
        let address: Address
        let fromPublicKey: Bool
    }

    private let capture = QRCaptureSession()
    private var cameraState: CameraState = .starting
    private var devices: [CameraDevice] = []
    private var deviceID: String?
    private var found: Found?
    /// The parts read so far of a key that a recovery sheet printed across several codes.
    private var keyParts = KeyPartCollector()
    /// The frames read so far of an animated code (AirGap Vault's, when it does not fit one).
    private var frames = UniformResource.Decoder()
    private var tasks: [Task<Void, Never>] = []
    private var isClosed = false

    private let cameraBox = Widget(gtk_overlay_new()!)
    private let picture = Widget(gtk_picture_new()!)
    private let placeholder = UI.vbox(spacing: 10)
    private let pickerGroup = Form.group([])
    private var picker: Widget?
    private let hint = UI.label(classes: ["dim-label"], wrap: true)
    private let scanner = UI.vbox(spacing: 10)
    private let foundPanel = UI.vbox(spacing: 14)
    private let partsLine = UI.label(wrap: true)
    private let partsRow: Widget
    private let framesLine = UI.label(wrap: true)
    private let framesRow: Widget
    private let noteLabel = UI.label(wrap: true).expand(h: true)
    private let noteRow: Widget
    private let title = Sheet.title("")

    /// With no account yet the sheet is a way in: keys and phrases, or an address to watch.
    private var isFirstRun: Bool { model.wallets.isEmpty }
    private var existing: Wallet? { found.flatMap { f in model.wallets.first { $0.address == f.address } } }
    private var canSend: Bool { found.map { model.canSendFromSelected && $0.address != model.selectedWallet?.address } ?? false }

    init(model: WalletViewModel) {
        partsRow = UI.hbox(spacing: 8, [UI.image(icon: "view-grid-symbolic").align(v: GTK_ALIGN_START), partsLine.expand(h: true)])
        framesRow = UI.hbox(spacing: 8, [UI.image(icon: "view-refresh-symbolic").align(v: GTK_ALIGN_START), framesLine.expand(h: true)])
        noteRow = UI.hbox(spacing: 8, [UI.image(icon: "dialog-warning-symbolic").align(v: GTK_ALIGN_START), noteLabel]).classes("warning-text")
        super.init(model: model, width: 480)

        gtk_picture_set_content_fit(picture.opaque, GTK_CONTENT_FIT_COVER)
        gtk_widget_set_overflow(cameraBox.pointer, GTK_OVERFLOW_HIDDEN)
        placeholder.align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER)
        gtk_overlay_set_child(cameraBox.opaque, picture.pointer)
        gtk_overlay_add_overlay(cameraBox.opaque, placeholder.pointer)
        cameraBox.classes("camera-box").size(height: 330)
        // Upstream: "A code shown on this Mac's own screen …"
        UI.setText(hint, isFirstRun
                   ? "Hold up a QR code of a secret key or a recovery phrase to import it, AirGap Vault's Pair Account code, or an address to watch it. A code shown on this computer's own screen can be read from a screenshot on the clipboard."
                   : "Hold up a QR code: a dApp's pairing code, an address or public key, a secret key or recovery phrase, or AirGap Vault's Pair Account code. A code shown on this computer's own screen can be read from a screenshot on the clipboard.")
        scanner.setChildren([cameraBox, pickerGroup, hint])
        UI.setText(title, isFirstRun ? "Import from QR code" : "Scan QR code")
        content.setChildren([title, scanner, foundPanel, partsRow, framesRow, noteRow])
        noteRow.isVisible = false
        UI.shortcut("<Control>v", on: dialog) { [weak self] in if self?.found == nil { self?.paste() } }

        let capture = capture
        tasks.append(Task { [weak self] in for await code in capture.codes { self?.handle(code) } })
        tasks.append(Task { [weak self] in for await frame in capture.frames { self?.show(frame) } })
        tasks.append(Task { [weak self] in for await failure in capture.failures { self?.cameraFailed(failure) } })
        // `.task { await startCamera() }` and `.onChange(of: model.hasCamera)`.
        trackers.append(Tracker { [weak self] in
            guard let self else { return }
            _ = self.model.hasCamera
            Task { @MainActor [weak self] in self?.startCamera() }
        })
        // The found panel's buttons follow the model, as SwiftUI's do: whether the address is in
        // the list, and whether the selected account can send.
        trackers.append(Tracker { [weak self] in
            guard let self else { return }
            _ = (self.model.wallets, self.model.selectedWallet, self.model.canSendFromSelected)
            if let found = self.found { self.fillFoundPanel(found) }
        })
        update()
    }

    private func update() {
        scanner.isVisible = found == nil
        foundPanel.isVisible = found != nil
        switch cameraState {
        case .running:
            placeholder.setChildren([])
        case .starting:
            let spinner = Widget(adw_spinner_new()!).size(width: 24, height: 24)
            placeholder.setChildren([spinner])
        case .failed(let message):
            placeholder.setChildren([UI.image(icon: "camera-disabled-symbolic", pixelSize: 32),
                                     UI.label(message, wrap: true, xalign: 0.5).size(width: 360)])
        case .missing:
            placeholder.setChildren([UI.image(icon: "camera-disabled-symbolic", pixelSize: 32), UI.label("No camera is connected.")])
        }
        picture.isVisible = cameraState == .running
        pickerGroup.isVisible = devices.count > 1 && cameraState == .running

        partsRow.isVisible = found == nil && !keyParts.isEmpty
        if partsRow.isVisible {
            UI.setText(partsLine, "A secret key in \(keyParts.count) codes: \(keyParts.received) read. Still needed: \(keyParts.missing.map(String.init).joined(separator: ", ")). Scan them in any order.")
        }
        framesRow.isVisible = found == nil && !frames.isEmpty
        if framesRow.isVisible {
            UI.setText(framesLine, "An animated code: \(frames.receivedFragments) of \(frames.expectedParts) parts read. Keep the code in view.")
        }

        if found == nil {
            let paste = button("Paste from Clipboard") { [unowned self] in self.paste() }
            paste.tooltip("Reads a QR code from an image on the clipboard, such as a screenshot, or a copied code")
            setButtons([paste, button("Choose Image…") { [unowned self] in self.chooseImage() }, cancelButton()])
        } else {
            setButtons([button("Scan Again") { [unowned self] in self.scanAgain() }, cancelButton()])
        }
    }

    private func setNote(_ text: String?) {
        UI.setText(noteLabel, text ?? "")
        noteRow.isVisible = text != nil
    }

    // MARK: Scanning

    private func startCamera() {
        guard found == nil, !isClosed else { return }
        devices = QRCamera.devices()
        if deviceID == nil || !devices.contains(where: { $0.id == deviceID }) { deviceID = QRCamera.preferred(among: devices)?.id }
        updatePicker()
        guard let deviceID else {
            capture.stop()
            cameraState = .missing
            update()
            return
        }
        capture.start(deviceID: deviceID)
        cameraState = .starting
        update()
    }

    /// The camera picker, shown when there are several.
    private func updatePicker() {
        let names = devices.map(\.name)
        let selected = devices.firstIndex { $0.id == deviceID } ?? 0
        if let picker {
            Form.setOptions(picker, names, selected: selected)
        } else {
            let row = Form.picker("Camera", options: names, selected: selected) { [unowned self] in
                guard let row = self.picker, let device = self.devices[safe: Form.selected(row)], device.id != self.deviceID else { return }
                self.deviceID = device.id
                if self.found == nil { self.startCamera() }
            }
            picker = row
            Form.setRows(pickerGroup, [row])
        }
    }

    private func show(_ frame: PlatformImage) {
        guard found == nil else { return }
        gtk_picture_set_paintable(picture.opaque, frame.texture)
        if cameraState != .running {
            cameraState = .running
            update()
        }
    }

    private func cameraFailed(_ message: String) {
        capture.stop()
        gtk_picture_set_paintable(picture.opaque, nil)
        cameraState = .failed(message)
        update()
    }

    private func scanAgain() {
        found = nil
        setNote(nil)
        keyParts = KeyPartCollector()
        frames = UniformResource.Decoder()
        foundPanel.setChildren([])
        startCamera()
    }

    private func paste() {
        let clipboard = gtk_widget_get_clipboard(content.pointer)!
        Task { [weak self] in
            let texts = await QRCamera.textsFromClipboard(clipboard)
            guard let self else { return }
            guard !texts.isEmpty else {
                self.setNote("The clipboard holds no QR code image and no text.")
                return
            }
            texts.forEach(self.handle)
        }
    }

    private final class Chosen {
        let onChoose: @MainActor (URL) -> Void
        init(_ onChoose: @escaping @MainActor (URL) -> Void) { self.onChoose = onChoose }
    }

    /// GTK's file chooser for an image (`.fileImporter(allowedContentTypes: [.image])` upstream).
    private func chooseImage() {
        let chooser = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(chooser, "Choose Image")
        let filter = gtk_file_filter_new()!
        gtk_file_filter_set_name(filter, "Images")
        gtk_file_filter_add_mime_type(filter, "image/*")
        let filters = g_list_store_new(gtk_file_filter_get_type())!
        g_list_store_append(filters, UnsafeMutableRawPointer(filter))
        gtk_file_dialog_set_filters(chooser, filters)
        gtk_file_dialog_set_default_filter(chooser, filter)
        g_object_unref(UnsafeMutableRawPointer(filters))
        g_object_unref(UnsafeMutableRawPointer(filter))
        let window = gtk_widget_get_root(content.pointer).map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        let box = Unmanaged.passRetained(Chosen { [weak self] url in self?.read(url) }).toOpaque()
        gtk_file_dialog_open(chooser, window, nil, { source, result, data in
            let chosen = Unmanaged<Chosen>.fromOpaque(data!).takeRetainedValue()
            defer { g_object_unref(source) }
            guard let file = gtk_file_dialog_open_finish(OpaquePointer(source), result, nil) else { return }
            defer { g_object_unref(UnsafeMutableRawPointer(file)) }
            guard let path = g_file_get_path(file) else { return }
            let url = URL(fileURLWithPath: String(cString: path))
            g_free(path)
            MainActor.assumeIsolated { chosen.onChoose(url) }
        }, box)
    }

    private func read(_ url: URL) {
        let codes = (try? Data(contentsOf: url)).flatMap { PlatformImage.decode($0, maxPixelSize: 4096) }.map(QRCode.decodeAll) ?? []
        guard !codes.isEmpty else {
            setNote("No QR code was found in that image.")
            return
        }
        codes.forEach(handle)
    }

    // MARK: What was scanned

    private func handle(_ text: String) {
        guard found == nil else { return }
        setNote(nil)
        switch QRPayload.classify(text) {
        case .pairing(let code):
            guard model.wallets.contains(where: { $0.keyKind.canSign }) else {
                setNote("That is a dApp's pairing code. Create or import an account first, then scan it again.")
                return
            }
            finish(.pair(code: code))
        case .secretKey(let key):
            finish(.importKey(.secretKey(key)))
        case .recoveryPhrase(let phrase):
            finish(.importKey(.recoveryPhrase(phrase)))
        case .keyPart(let part):
            switch keyParts.add(part) {
            case .needMore: break
            case .complete(let key): finish(.importKey(.secretKey(key)))
            case .invalid: setNote("Those codes do not fit together into a key. Scan every part of the same recovery sheet again.")
            }
            update()
        case .address(let address):
            show(Found(address: address, fromPublicKey: false))
        case .publicKey(let key):
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.show(Found(address: try await self.model.address(forScannedPublicKey: key), fromPublicKey: true))
                } catch {
                    self.setNote("That looks like a public key, but Signet could not read it.")
                }
            }
        case .uniformResource(let part):
            do {
                if case .complete(let payload) = try frames.receive(part) { readAirGap(payload) }
            } catch {
                frames = UniformResource.Decoder()
                setNote("That animated code could not be read. Hold it steady and scan it again.")
            }
            update()
        case .airGapLegacy:
            setNote("That is an AirGap code in its older format. In AirGap Vault, open QR Details under the code and choose QR Code V3.")
        case .unknown:
            setNote("That code is not a pairing code, an address or a key that Signet can use.")
        }
    }

    /// An AirGap message: a Vault's account share is the only one that makes sense here.
    private func readAirGap(_ payload: [UInt8]) {
        do {
            let accounts = try AirGap.accounts(in: AirGap.messages(from: payload))
            guard !accounts.isEmpty else {
                setNote("That AirGap code holds no Tezos account. In AirGap Vault, open the Tezos account and choose Pair Account.")
                return
            }
            finish(.airGap(accounts))
        } catch AirGap.Error.unsupportedVersion {
            setNote("That AirGap code is in a format Signet does not read. In AirGap Vault, choose QR Code V3 under QR Details.")
        } catch {
            setNote("That code is not one Signet can use.")
        }
    }

    private func show(_ result: Found) {
        guard found == nil else { return }
        capture.stop()
        found = result
        fillFoundPanel(result)
        update()
    }

    /// Stops the camera and closes; the home view opens the next sheet once this one has gone.
    private func finish(_ handoff: WalletViewModel.ScanHandoff) {
        guard model.pendingScan == nil else { return }
        capture.stop()
        model.pendingScan = handoff
        dismiss()
    }

    // MARK: An address

    private func fillFoundPanel(_ found: Found) {
        var lines = [UI.label(found.address.value, classes: ["address"], wrap: true)]
        gtk_label_set_selectable(lines[0].opaque, 1)
        if let existing {
            lines.append(UI.hbox(spacing: 4, [UI.image(icon: "object-select-symbolic", pixelSize: 12), UI.label("In your list as “\(existing.alias)”")]).classes("dim-label"))
        } else if found.address.isContract {
            lines.append(UI.label("Smart contract", classes: ["dim-label", "caption"]))
        } else if let scheme = found.address.scheme {
            lines.append(UI.label(found.fromPublicKey ? "\(scheme.displayName), from the scanned public key" : scheme.displayName, classes: ["dim-label", "caption"]))
        }
        let card = UI.hbox(spacing: 12, [AccountAvatarView(address: found.address, size: 44).root,
                                         UI.vbox(spacing: 3, lines).align(v: GTK_ALIGN_CENTER).expand(h: true)]).classes("scan-found")
        let note = UI.label("Check the address against where the code came from before you use it.", classes: ["dim-label"], wrap: true)

        var actions: [Widget] = [UI.hspacer()]
        if existing == nil {
            actions.append(UI.button(isFirstRun ? "Watch This Address…" : "Add to Address Book…") { [unowned self] in
                self.finish(.addAddress(found.address))
            })
        }
        if canSend {
            actions.append(UI.button("Send…", classes: ["suggested-action"]) { [unowned self] in self.finish(.send(found.address)) })
        }
        foundPanel.setChildren([card, note, UI.hbox(spacing: 8, actions)])
    }

    /// `.onDisappear { capture.stop() }`: the camera goes off, and the parts of a key read so
    /// far are dropped.
    override func closed() {
        isClosed = true
        capture.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        keyParts = KeyPartCollector()
        frames = UniformResource.Decoder()
        gtk_picture_set_paintable(picture.opaque, nil)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
