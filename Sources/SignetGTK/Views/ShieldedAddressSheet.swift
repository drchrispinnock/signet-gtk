import CAdwaita
import Foundation

/// The account's shielded address, to give to whoever will send to it, and the network's
/// shielded address book. A shielded address is the payment address record itself (there is
/// no short form in the protocol), so it is shown as the JSON other wallets take, with a
/// fingerprint to read out to the sender. "New address" makes a fresh one so that two payers
/// cannot tell they paid the same wallet. The GTK counterpart of upstream's
/// `Views/ShieldedAddressSheet.swift`.
@MainActor
final class ShieldedAddressSheet: Sheet {
    private var address: ShieldedReceiveAddress?
    private var loading = false
    private var copied = false
    private var contacts: [ShieldedContact] = []
    private var parsed: ShieldedContact?
    private var parseError: String?
    private var parseTask: Task<Void, Never>?

    private let own = UI.vbox(spacing: 8)
    private let ownBody = UI.vbox(spacing: 8)
    private let bookList = UI.vbox(spacing: 6)
    private let nameEntry = Widget(gtk_entry_new()!)
    private let pasteBox = ShieldedJSONEditor(placeholder: "Paste a shielded address", height: 60)
    private let addButton: Widget
    private let parseLine = UI.label(classes: ["caption"], wrap: true)

    private var wallet: Wallet? { model.selectedWallet }

    init(model: WalletViewModel) {
        addButton = UI.button("Add") {}
        super.init(model: model, width: 620)
        let header = Sheet.accountTitle("Shielded address", wallet: model.selectedWallet).root
        own.setChildren([UI.label("Your address", classes: ["heading"]), ownBody])
        PasswordEntry.setPlaceholder(nameEntry, "Name")
        nameEntry.size(width: 160).align(v: GTK_ALIGN_START)
        Signals.connect(nameEntry, "changed") { [unowned self] in self.updateAdd() }
        pasteBox.onChange = { [unowned self] in self.parseNew() }
        Signals.connect(addButton, "clicked") { [unowned self] in self.add() }
        addButton.align(v: GTK_ALIGN_START)
        let book = UI.vbox(spacing: 8, [
            UI.label("Address book", classes: ["heading"]),
            bookList,
            UI.hbox(spacing: 8, [nameEntry, pasteBox.root.expand(h: true), addButton]),
            parseLine,
        ])
        content.setChildren([header, own, book])
        setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        renderBook()
        // The progress line while the address is built follows the model.
        trackers.append(Tracker { [unowned self] in
            _ = (self.model.shieldProgress, self.model.canShield)
            self.renderOwn()
        })
        Task { await load() }
    }

    // MARK: Pieces

    private func renderOwn() {
        if let address {
            let fingerprint = UI.label("fingerprint \(SendShieldedSheet.short(address.fingerprint))", classes: ["monospace", "dim-label"])
            gtk_label_set_selectable(fingerprint.opaque, 1)
            gtk_widget_set_focusable(fingerprint.pointer, 0)
            let copy = UI.button(copied ? "Copied" : "Copy") { [unowned self] in
                UI.copyToClipboard(address.json, from: self.content)
                self.copied = true
                self.renderOwn()
            }
            let fresh = UI.button("New address") { [unowned self] in Task { await self.makeNew() } }
            fresh.isSensitive = !loading
            let json = UI.label(address.json, classes: ["monospace", "caption"], wrap: true)
            gtk_label_set_wrap_mode(json.opaque, PANGO_WRAP_CHAR)
            gtk_label_set_selectable(json.opaque, 1)
            gtk_widget_set_focusable(json.pointer, 0)
            let scroller = Widget(gtk_scrolled_window_new()!)
            gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_child(scroller.opaque, json.margins(top: 6, bottom: 6, start: 6, end: 6).pointer)
            scroller.size(height: 110).classes("card")
            ownBody.setChildren([
                UI.hbox(spacing: 8, [UI.label("Address #\(address.index)", classes: ["dim-label"]), fingerprint, UI.hspacer(), copy, fresh]),
                scroller,
                UI.label("Give the sender this JSON (Copy puts all of it on the clipboard) and read them the fingerprint so they can check what they pasted. Anything sent to it shows in your Shielded balance; nothing on the rollup links it to you.",
                         classes: ["dim-label"], wrap: true),
                UI.label("The key that spends what arrives is kept unencrypted in the wallet directory and its backups, even when this account's own key has a password.",
                         classes: ["dim-label"], wrap: true),
            ])
        } else if loading {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            ownBody.setChildren([UI.hbox(spacing: 6, [spinner, UI.label(model.shieldProgress?.text ?? "Preparing…", classes: ["dim-label"])])])
        } else if !model.canShield {
            ownBody.setChildren([UI.label("Shielded addresses need Shielded Transactions on for this network and an account Signet can sign for.", classes: ["warning-text"], wrap: true)])
        } else {
            ownBody.setChildren([])
        }
    }

    private func renderBook() {
        var rows: [Widget] = []
        if contacts.isEmpty { rows.append(UI.label("No shielded addresses saved yet.", classes: ["dim-label"])) }
        for contact in contacts {
            let fingerprint = UI.label(SendShieldedSheet.short(contact.fingerprint), classes: ["monospace", "dim-label"])
            gtk_label_set_selectable(fingerprint.opaque, 1)
            gtk_widget_set_focusable(fingerprint.pointer, 0)
            rows.append(UI.hbox(spacing: 8, [UI.label(contact.name), fingerprint, UI.hspacer(),
                                             UI.button("Remove") { [unowned self] in self.remove(contact) }]))
        }
        bookList.setChildren(rows)
        let pasted = !pasteBox.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let parseError, pasted {
            UI.setText(parseLine, parseError)
            parseLine.setClass("warning-text", true)
            parseLine.setClass("dim-label", false)
            parseLine.isVisible = true
        } else if let parsed {
            UI.setText(parseLine, "Fingerprint \(SendShieldedSheet.short(parsed.fingerprint))")
            parseLine.setClass("warning-text", false)
            parseLine.setClass("dim-label", true)
            parseLine.isVisible = true
        } else {
            parseLine.isVisible = false
        }
        updateAdd()
    }

    private func updateAdd() {
        let name = String(cString: gtk_editable_get_text(nameEntry.opaque))
        addButton.isSensitive = parsed != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Actions

    private func load() async {
        contacts = (try? model.shieldedContacts()) ?? []
        renderBook()
        guard model.canShield else { return }
        loading = true
        renderOwn()
        defer { loading = false; renderOwn() }
        do { address = try await model.shieldedReceiveAddress() } catch { setError(error.localizedDescription) }
    }

    private func makeNew() async {
        setError(nil)
        loading = true
        renderOwn()
        defer { loading = false; renderOwn() }
        do { address = try await model.makeShieldedAddress(); copied = false } catch { setError(error.localizedDescription) }
    }

    private func parseNew() {
        parseTask?.cancel()
        parsed = nil
        parseError = nil
        renderBook()
        let json = pasteBox.text
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parseTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let contact = try await model.shieldedRecipient(from: json)
                if !Task.isCancelled { parsed = contact }
            } catch {
                if !Task.isCancelled { parseError = error.localizedDescription }
            }
            if !Task.isCancelled { renderBook() }
        }
    }

    private func add() {
        guard let parsed else { return }
        setError(nil)
        do {
            try model.addShieldedContact(parsed, name: String(cString: gtk_editable_get_text(nameEntry.opaque)))
            contacts = (try? model.shieldedContacts()) ?? []
            gtk_editable_set_text(nameEntry.opaque, "")
            pasteBox.text = ""
        } catch {
            setError(error.localizedDescription)
        }
        renderBook()
    }

    private func remove(_ contact: ShieldedContact) {
        setError(nil)
        do { try model.removeShieldedContact(contact.fingerprint); contacts = (try? model.shieldedContacts()) ?? [] } catch { setError(error.localizedDescription) }
        renderBook()
    }

    override func closed() { parseTask?.cancel() }
}

/// SwiftUI's `TextEditor` with a placeholder laid over it while empty, in monospace: where a
/// shielded address (a long JSON record) is pasted.
@MainActor
final class ShieldedJSONEditor {
    let root: Widget
    private let view = Widget(gtk_text_view_new()!)
    private let placeholder: Widget
    var onChange: (@MainActor () -> Void)?

    init(placeholder text: String, height: Int32) {
        gtk_text_view_set_wrap_mode(view.as(), GTK_WRAP_CHAR)
        gtk_text_view_set_monospace(view.as(), 1)
        gtk_text_view_set_accepts_tab(view.as(), 0)
        view.classes("phrase-editor", "caption").accessibleLabel(text)
        placeholder = UI.label(text, classes: ["dim-label", "caption"]).align(h: GTK_ALIGN_START, v: GTK_ALIGN_START).margins(top: 6, start: 8)
        gtk_widget_set_can_target(placeholder.pointer, 0)
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, view.pointer)
        scroller.size(height: height)
        let overlay = Widget(gtk_overlay_new()!)
        gtk_overlay_set_child(overlay.opaque, scroller.pointer)
        gtk_overlay_add_overlay(overlay.opaque, placeholder.pointer)
        root = overlay
        root.retain(self, key: "signet-json-editor")
        Signals.connect(Widget(OpaquePointer(gtk_text_view_get_buffer(view.as())!)), "changed") { [unowned self] in
            self.placeholder.isVisible = self.text.isEmpty
            self.onChange?()
        }
    }

    var text: String {
        get {
            let buffer = gtk_text_view_get_buffer(view.as())
            var start = GtkTextIter(), end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            guard let chars = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
            defer { g_free(chars) }
            return String(cString: chars)
        }
        set { gtk_text_buffer_set_text(gtk_text_view_get_buffer(view.as()), newValue, -1) }
    }
}
