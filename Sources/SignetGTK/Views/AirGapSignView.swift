import CAdwaita
import Foundation

/// The port's half of upstream's `AirGapSigning`: where the Mac slides an AppKit sheet down over
/// the deepest sheet of the front window, here the panel is a dialog stacked over whatever the
/// window shows, so the Send (or other) sheet that asked stays beneath it.
extension AirGapSigning {
    private static var panel: AirGapSignView?

    func presentPanel(_ session: AirGapSignSession) {
        guard let (model, window) = SignetApp.current else {
            session.cancel()
            return
        }
        let panel = AirGapSignView(model: model, session: session)
        Self.panel = panel
        panel.present(over: window)
    }

    func closePanel() {
        let panel = Self.panel
        Self.panel = nil
        if let panel, !panel.isClosed { panel.dismiss() }
    }
}

/// Upstream's `AirGapSignView`: the request code, then the camera for the reply. Closing the
/// panel any other way than with the Vault's signature cancels the signing.
@MainActor
final class AirGapSignView: Sheet {
    private enum CameraState: Equatable { case starting, running, failed(String), missing }

    private let session: AirGapSignSession
    private let capture = QRCaptureSession()
    private var cameraState: CameraState = .starting
    private var devices: [CameraDevice] = []
    private var deviceID: String?
    private var frameIndex = 0
    private var tasks: [Task<Void, Never>] = []
    private(set) var isClosed = false

    /// Every frame of the request drawn once; an animated code steps through them.
    private let codes: [PlatformImage]
    private let code = Widget(gtk_image_new()!)
    private let request = UI.vbox(spacing: 12)
    private let reply = UI.vbox(spacing: 10)
    private let cameraBox = Widget(gtk_overlay_new()!)
    private let picture = Widget(gtk_picture_new()!)
    private let placeholder = UI.vbox(spacing: 10)
    private let pickerGroup = Form.group([])
    private var picker: Widget?
    private let progressLine = UI.label(wrap: true)
    private let noteLabel = UI.label(wrap: true).expand(h: true)
    private let noteRow: Widget

    init(model: WalletViewModel, session: AirGapSignSession) {
        self.session = session
        codes = session.frames.compactMap { QRCode.image(for: $0, size: 300, correction: "L") }
        noteRow = UI.hbox(spacing: 8, [UI.image(icon: "dialog-warning-symbolic").align(v: GTK_ALIGN_START), noteLabel]).classes("warning-text")
        super.init(model: model, width: 480)

        let heading = UI.hbox(spacing: 8, [UI.image(icon: "phone-symbolic", pixelSize: 20), Sheet.title("Sign with AirGap Vault")])
        let account = UI.label("Account \(Address(session.address).shortened())", classes: ["dim-label", "monospace"])

        if let first = codes.first {
            gtk_image_set_from_paintable(code.opaque, first.texture)
            gtk_image_set_pixel_size(code.opaque, Int32(first.width))
        }
        // Upstream: "… up to this Mac's camera."
        request.setChildren([
            UI.vbox(spacing: 0, [code]).classes("qr-box").align(h: GTK_ALIGN_CENTER),
            UI.vbox(spacing: 4, [
                UI.label("1. In AirGap Vault, tap Scan and point the phone at this code\(session.frames.count > 1 ? " until it has read every part" : "").", wrap: true),
                UI.label("2. Check the operation on the phone and approve it.", wrap: true),
                UI.label("3. Click Scan Vault's Reply and hold the code the Vault shows up to this computer's camera.", wrap: true),
            ]),
        ])

        gtk_picture_set_content_fit(picture.opaque, GTK_CONTENT_FIT_COVER)
        gtk_widget_set_overflow(cameraBox.pointer, GTK_OVERFLOW_HIDDEN)
        placeholder.align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER)
        gtk_overlay_set_child(cameraBox.opaque, picture.pointer)
        gtk_overlay_add_overlay(cameraBox.opaque, placeholder.pointer)
        cameraBox.classes("camera-box").size(height: 300)
        reply.setChildren([cameraBox, pickerGroup, progressLine])

        content.setChildren([UI.vbox(spacing: 4, [heading, account]), request, reply, noteRow])
        UI.shortcut("<Control>v", on: dialog) { [weak self] in if self?.session.phase == .scanning { self?.paste() } }

        let capture = capture
        tasks.append(Task { [weak self] in for await text in capture.codes { self?.session.receive(text) } })
        tasks.append(Task { [weak self] in for await frame in capture.frames { self?.show(frame) } })
        tasks.append(Task { [weak self] in for await failure in capture.failures { self?.cameraFailed(failure) } })
        if codes.count > 1 {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.nextFrame()
                }
            })
        }
        // The session changes as codes arrive: its phase, its note and the frames read so far.
        trackers.append(Tracker { [weak self] in
            guard let self else { return }
            _ = (self.session.phase, self.session.note, self.session.decoder.receivedFragments)
            self.update()
        })
    }

    private func update() {
        let scanning = session.phase == .scanning
        request.isVisible = !scanning
        reply.isVisible = scanning

        switch cameraState {
        case .running:
            placeholder.setChildren([])
        case .starting:
            placeholder.setChildren([Widget(adw_spinner_new()!).size(width: 24, height: 24)])
        case .failed(let message):
            placeholder.setChildren([UI.image(icon: "camera-disabled-symbolic", pixelSize: 32),
                                     UI.label(message, wrap: true, xalign: 0.5).size(width: 360)])
        case .missing:
            placeholder.setChildren([UI.image(icon: "camera-disabled-symbolic", pixelSize: 32),
                                     UI.label("No camera is connected. Paste a screenshot of the Vault's code instead.", wrap: true, xalign: 0.5).size(width: 360)])
        }
        picture.isVisible = cameraState == .running
        pickerGroup.isVisible = devices.count > 1 && cameraState == .running

        if session.isCollecting {
            progressLine.removeClass("dim-label")
            UI.setText(progressLine, "An animated code: \(session.decoder.receivedFragments) of \(session.decoder.expectedParts) parts read. Keep it in view.")
        } else {
            progressLine.classes("dim-label")
            UI.setText(progressLine, "Hold up the signed code AirGap Vault shows after you approve. Signet checks it signs exactly this operation before sending.")
        }

        UI.setText(noteLabel, session.note ?? "")
        noteRow.isVisible = session.note != nil

        let cancel = button("Cancel", role: .cancel) { [unowned self] in
            self.capture.stop()
            self.session.cancel()
        }
        if scanning {
            let paste = button("Paste from Clipboard") { [unowned self] in self.paste() }
            paste.tooltip("Reads the Vault's reply from a screenshot or image on the clipboard")
            setButtons([button("Show Request Again") { [unowned self] in self.showRequest() }, paste, cancel])
        } else {
            setButtons([cancel, button("Scan Vault's Reply", role: .prominent, isDefault: true) { [unowned self] in self.scan() }])
        }
    }

    private func nextFrame() {
        guard !codes.isEmpty, session.phase == .showing else { return }
        frameIndex += 1
        gtk_image_set_from_paintable(code.opaque, codes[frameIndex % codes.count].texture)
    }

    private func showRequest() {
        capture.stop()
        gtk_picture_set_paintable(picture.opaque, nil)
        session.note = nil
        session.phase = .showing
    }

    private func scan() {
        session.note = nil
        session.phase = .scanning
        startCamera()
    }

    // MARK: The camera

    /// Linux has no camera permission to ask for: the device node opens or it does not, and
    /// `capture.failures` says why.
    private func startCamera() {
        devices = QRCamera.devices()
        if deviceID == nil || !devices.contains(where: { $0.id == deviceID }) { deviceID = QRCamera.preferred(among: devices)?.id }
        updatePicker()
        guard let deviceID else {
            cameraState = .missing
            update()
            return
        }
        capture.start(deviceID: deviceID)
        cameraState = .starting
        update()
    }

    private func updatePicker() {
        let names = devices.map(\.name)
        let selected = devices.firstIndex { $0.id == deviceID } ?? 0
        if let picker {
            Form.setOptions(picker, names, selected: selected)
        } else {
            let row = Form.picker("Camera", options: names, selected: selected) { [unowned self] in
                guard let row = self.picker else { return }
                let index = Form.selected(row)
                guard self.devices.indices.contains(index), self.devices[index].id != self.deviceID else { return }
                self.deviceID = self.devices[index].id
                if self.session.phase == .scanning { self.startCamera() }
            }
            picker = row
            Form.setRows(pickerGroup, [row])
        }
    }

    private func show(_ frame: PlatformImage) {
        guard session.phase == .scanning else { return }
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

    private func paste() {
        let clipboard = gtk_widget_get_clipboard(content.pointer)!
        Task { [weak self] in
            let texts = await QRCamera.textsFromClipboard(clipboard)
            guard let self else { return }
            guard !texts.isEmpty else {
                self.session.note = "The clipboard holds no QR code image and no text."
                return
            }
            texts.forEach(self.session.receive)
        }
    }

    /// `.onDisappear { capture.stop() }`; closed with Escape, it is a cancel.
    override func closed() {
        isClosed = true
        capture.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        gtk_picture_set_paintable(picture.opaque, nil)
        session.cancel()
    }
}
