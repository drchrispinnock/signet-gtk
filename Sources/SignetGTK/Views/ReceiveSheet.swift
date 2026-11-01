import CAdwaita
import Foundation

/// Shows the selected wallet's address as a QR code and text so someone can send tez to it. The
/// GTK counterpart of upstream's `Views/ReceiveSheet.swift`, Tezos side only: the
/// `ChainSidePicker` that switches to the account's Etherlink address is not ported.
@MainActor
final class ReceiveSheet: Sheet {
    let wallet: Wallet
    let domains: [String]

    init(model: WalletViewModel, wallet: Wallet, domains: [String]) {
        self.wallet = wallet
        self.domains = domains
        super.init(model: model, width: 420)
        let address = wallet.address.value

        var names = [UI.label(wallet.alias, classes: ["heading"], xalign: 0.5)]
        names += domains.map { UI.label($0, classes: ["dim-label"], xalign: 0.5) }

        let code: Widget
        if let image = QRCode.image(for: address, size: 220) {
            // Drawn at its own size, so every module is whole pixels (`.interpolation(.none)`).
            code = Widget(gtk_image_new_from_paintable(image.texture)!)
            gtk_image_set_pixel_size(code.opaque, Int32(image.width))
        } else {
            code = UI.label("Could not draw QR code", classes: ["dim-label"], xalign: 0.5).size(width: 220, height: 220)
        }
        let codeBox = UI.vbox(spacing: 0, [code]).classes("qr-box").align(h: GTK_ALIGN_CENTER)
        codeBox.accessibleLabel("QR code for \(address)")

        let addressLabel = UI.label(address, classes: ["address"], wrap: true, xalign: 0.5)
        gtk_label_set_selectable(addressLabel.opaque, 1)
        gtk_label_set_justify(addressLabel.opaque, GTK_JUSTIFY_CENTER)
        let note = UI.label("Only send tez and Tezos tokens to this address\(domains.isEmpty ? "." : ", or to \(domains[0]).")",
                            classes: ["dim-label"], wrap: true, xalign: 0.5)
        gtk_label_set_justify(note.opaque, GTK_JUSTIFY_CENTER)

        content.setChildren([
            UI.label("Receive", classes: ["title-2"], xalign: 0.5),
            UI.vbox(spacing: 4, names), codeBox, addressLabel, note,
        ])

        let copy = UI.button(content: UI.hbox(spacing: 6, [UI.image(icon: "edit-copy-symbolic"), UI.label("Copy address")]),
                             classes: ["suggested-action"]) {}
        let copyLabel = gtk_widget_get_last_child(gtk_button_get_child(copy.as()))!
        Signals.connect(copy, "clicked") {
            UI.copyToClipboard(address, from: copy)
            gtk_label_set_text(OpaquePointer(copyLabel), "Copied")
        }
        let done = button("Done", isDefault: true) { [unowned self] in self.dismiss() }
        buttons.setChildren([done])
        focus(done)
        status.setChildren([copy])
        status.isVisible = true
        // ⌘⇧C upstream.
        UI.shortcut("<Control><Shift>c", on: dialog) { gtk_widget_activate(copy.pointer) }
    }
}
