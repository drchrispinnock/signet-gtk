import CAdwaita
import Foundation

/// Shows the selected wallet's address as a QR code and text so someone can send tez to it.
/// With Layer 2 on, the logo at the top left has a drop-down beside it (`ChainSidePicker`) that
/// switches to the account's address on Etherlink's EVM side (`EtherlinkAlias`). That address
/// is only shown once it exists on chain (`EtherlinkAliasStatus.linked`): until the account has
/// made its first cross-interface call, tez sent to it would sit at an address nobody controls,
/// so the sheet offers to link the account first (a no-op gateway call paid on Etherlink). The
/// GTK counterpart of upstream's `Views/ReceiveSheet.swift`.
@MainActor
final class ReceiveSheet: Sheet {
    let wallet: Wallet
    let domains: [String]
    /// Offer the Etherlink address too: Layer 2 is on and the key is usable on the rollup.
    let showsEtherlink: Bool

    enum AliasState: Equatable {
        case checking
        case linked(String)
        /// `unfunded`: the account holds no tez on Etherlink, so the link (paid there) cannot be
        /// estimated or sent until some are bridged across; the node's refusal is not shown.
        case unlinked(fee: Decimal?, problem: String?, unfunded: Bool = false)
        case linking
        case failed(String)
    }

    private var side: ChainSide = .tezos
    private var alias: AliasState = .checking { didSet { render() } }
    private var estimate: TransferEstimate?
    private let names = UI.vbox(spacing: 4)
    private let body = UI.vbox(spacing: 16)
    private let copyButton: Widget
    private let copyLabel = UI.label("Copy address")
    private let passphraseField: Widget
    private var linkButton: Widget?
    /// Bumped on every side change, so a check that finishes late is dropped (`.task(id: side)`).
    private var generation = 0

    private var needsPassphrase: Bool { wallet.keyKind == .encrypted }

    init(model: WalletViewModel, wallet: Wallet, domains: [String], showsEtherlink: Bool) {
        self.wallet = wallet
        self.domains = domains
        self.showsEtherlink = showsEtherlink
        copyButton = UI.button(content: UI.hbox(spacing: 6, [UI.image(icon: "edit-copy-symbolic"), copyLabel]), classes: ["suggested-action"]) {}
        passphraseField = PasswordEntry.make(placeholder: "Password for \(wallet.alias)", onChange: { _ in })
        super.init(model: model, width: 420)

        let picker = ChainSidePicker(canSwitch: showsEtherlink) { [unowned self] in self.switchSide(to: $0) }
        // `ZStack { title; HStack { picker; Spacer() } }`: the title centred over the whole width.
        let title = UI.label("Receive", classes: ["title-2"], xalign: 0.5)
        let header = Widget(gtk_overlay_new()!)
        gtk_overlay_set_child(header.opaque, title.pointer)
        picker.root.align(h: GTK_ALIGN_START, v: GTK_ALIGN_CENTER)
        gtk_overlay_add_overlay(header.opaque, picker.root.pointer)
        content.setChildren([header, names, body])

        Signals.connect(copyButton, "clicked") { [unowned self] in
            guard let address = self.address else { return }
            UI.copyToClipboard(address, from: self.copyButton)
            UI.setText(self.copyLabel, "Copied")
        }
        Signals.connect(passphraseField, "changed") { [unowned self] in self.updateLinkButton() }
        let done = button("Done", isDefault: true) { [unowned self] in self.dismiss() }
        setButtons([done])
        status.setChildren([copyButton])
        status.isVisible = true
        // ⌘⇧C upstream.
        UI.shortcut("<Control><Shift>c", on: dialog) { [unowned self] in if self.address != nil { gtk_widget_activate(self.copyButton.pointer) } }
        render()
        focus(done)
    }

    private var address: String? {
        switch side {
        case .tezos: wallet.address.value
        case .etherlink: if case .linked(let evm) = alias { evm } else { nil }
        }
    }

    private func switchSide(to side: ChainSide) {
        self.side = side
        generation += 1
        UI.setText(copyLabel, "Copy address")
        if side == .etherlink {
            Task { await checkAlias() }
        }
        render()
    }

    // MARK: Content

    private func render() {
        var nameRows = [UI.label(wallet.alias, classes: ["heading"], xalign: 0.5)]
        if side == .tezos {
            nameRows += domains.map { UI.label($0, classes: ["dim-label"], xalign: 0.5) }
        } else {
            nameRows.append(UI.label("on Etherlink", classes: ["dim-label"], xalign: 0.5))
        }
        names.setChildren(nameRows)
        if let address {
            body.setChildren(addressViews(address))
        } else {
            body.setChildren([linkViews()])
        }
        copyButton.isVisible = address != nil
        canClose = alias != .linking || side == .tezos
    }

    private func addressViews(_ address: String) -> [Widget] {
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

        let addressLabel = centred(UI.label(address, classes: ["address"], wrap: true, xalign: 0.5))
        gtk_label_set_selectable(addressLabel.opaque, 1)
        return [codeBox, addressLabel, centred(UI.label(note, classes: ["dim-label"], wrap: true, xalign: 0.5))]
    }

    private func centred(_ label: Widget) -> Widget {
        gtk_label_set_justify(label.opaque, GTK_JUSTIFY_CENTER)
        return label
    }

    private func paragraph(_ text: String, style: String = "dim-label") -> Widget {
        centred(UI.label(text, classes: [style], wrap: true, xalign: 0.5))
    }

    private func spinner() -> Widget {
        let spinner = Widget(gtk_spinner_new()!)
        gtk_spinner_start(spinner.opaque)
        return spinner.align(h: GTK_ALIGN_CENTER)
    }

    /// The Etherlink side before the alias exists: what is going on, and the way to link.
    private func linkViews() -> Widget {
        var rows: [Widget] = []
        linkButton = nil
        switch alias {
        case .checking:
            rows = [spinner(), paragraph("Checking whether this account is known on Etherlink…")]
        case .linking:
            rows = [spinner(), paragraph("Linking to Etherlink…")]
            if wallet.keyKind == .ledger { rows.append(paragraph("Confirm the link on your Ledger…")) }
        case .failed(let message):
            rows = [paragraph(message, style: "error-text"),
                    UI.button("Try again") { [unowned self] in Task { await self.checkAlias() } }.align(h: GTK_ALIGN_CENTER)]
        case .unlinked(let fee, let problem, let unfunded):
            rows.append(paragraph("This account has no address on Etherlink's EVM side yet. Etherlink creates one the first time the account calls across from its Tezos side; tez sent there before that would be stuck at an address nobody controls."))
            if unfunded {
                rows.append(paragraph("Linking sends a small no-op call from this account on Etherlink, paid there, and this account holds no tez on Etherlink yet. Use Bridge… in the menu to move a little across, then come back here."))
                rows.append(UI.button("Check again") { [unowned self] in Task { await self.checkAlias() } }.align(h: GTK_ALIGN_CENTER))
            } else if wallet.keyKind.canSign {
                rows.append(paragraph("Linking sends a small no-op call from this account on Etherlink. It needs a little tez there to pay the fee (use Bridge… first)."))
                if needsPassphrase {
                    // Kept across renders, so it is taken out of the box it was in first.
                    if let parent = gtk_widget_get_parent(passphraseField.pointer) {
                        g_object_ref(passphraseField.raw)
                        gtk_box_remove(UnsafeMutableRawPointer(parent).assumingMemoryBound(to: GtkBox.self), passphraseField.pointer)
                        rows.append(passphraseField.size(width: 260).align(h: GTK_ALIGN_CENTER))
                        g_object_unref(passphraseField.raw)
                    } else {
                        rows.append(passphraseField.size(width: 260).align(h: GTK_ALIGN_CENTER))
                    }
                }
                if let problem { rows.append(paragraph(problem, style: "warning-text")) }
                let link = UI.button(fee.map { "Link to Etherlink (fee \(AssetBalance.format($0, symbol: "tz")))" } ?? "Link to Etherlink",
                                     classes: ["suggested-action"]) { [unowned self] in Task { await self.link() } }
                linkButton = link
                linkFee = fee
                updateLinkButton()
                rows.append(link.align(h: GTK_ALIGN_CENTER))
            } else {
                rows.append(paragraph("Link it from a wallet that holds this account's key."))
            }
        case .linked:
            break
        }
        return UI.vbox(spacing: 12, rows).size(width: 360, height: 244).align(h: GTK_ALIGN_CENTER)
    }

    private var linkFee: Decimal?

    private func updateLinkButton() {
        linkButton?.isSensitive = linkFee != nil && !(needsPassphrase && PasswordEntry.text(passphraseField).isEmpty)
    }

    private var note: String {
        switch side {
        case .tezos:
            "Only send tez and Tezos tokens to this address\(domains.isEmpty ? "." : ", or to \(domains[0]).")"
        case .etherlink:
            "This account's address on Etherlink's EVM side. Tez sent to it on Etherlink are forwarded to this account; its own address on Etherlink's Michelson side is the Tezos one."
        }
    }

    // MARK: Actions

    private func checkAlias() async {
        let generation = generation
        func set(_ state: AliasState) { if generation == self.generation { alias = state } }
        set(.checking)
        do {
            guard let status = try await model.etherlinkAliasStatus() else { set(.failed("Layer 2 is off for this network.")); return }
            if case .linked(let evm) = status { set(.linked(evm)); return }
            guard wallet.keyKind.canSign else { set(.unlinked(fee: nil, problem: nil)); return }
            // A fresh account has nothing on Etherlink to pay the link with: say so instead of
            // asking the node, whose refusal (an empty implicit contract) would read as a fault.
            if model.etherlinkSpendable == 0 { set(.unlinked(fee: nil, problem: nil, unfunded: true)); return }
            do {
                let fee = try await model.estimateEtherlinkLink()
                estimate = fee
                set(.unlinked(fee: fee.fee, problem: nil))
            } catch ChainError.cannotPayFee {
                set(.unlinked(fee: nil, problem: nil, unfunded: true))
            } catch {
                set(.unlinked(fee: nil, problem: "The link cannot be estimated: \(error.localizedDescription)"))
            }
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    private func link() async {
        let fee = estimate?.fee
        alias = .linking
        do {
            _ = try await model.linkToEtherlink(limits: estimate?.limits, passphrase: needsPassphrase ? PasswordEntry.text(passphraseField) : nil)
            gtk_editable_set_text(passphraseField.opaque, "")
            await checkAlias()
        } catch ChainError.cannotPayFee {
            alias = .unlinked(fee: nil, problem: nil, unfunded: true)
        } catch {
            alias = .unlinked(fee: fee, problem: error.localizedDescription)
        }
    }

    override func closed() { gtk_editable_set_text(passphraseField.opaque, "") }
}
