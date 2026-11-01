import CAdwaita
import Foundation

/// Adds an address book entry: a named address Signet holds no key for. The GTK counterpart of
/// upstream's `Views/AddAddressSheet.swift`.
@MainActor
final class AddAddressSheet: Sheet {
    private var aliasField: Widget!
    private var useSuggestion: Widget!
    private var addressField: Widget!
    private let preview = UI.hbox(spacing: 10)
    private var addButton: Widget!
    private var previewDomains: [String] = []
    private var suggestedName: String?
    private var isAdding = false
    private var lookup: Task<Void, Never>?

    init(model: WalletViewModel) {
        super.init(model: model, width: 480)
        aliasField = Form.entry("Name", onChange: { [unowned self] in self.update() })
        useSuggestion = UI.button("", classes: ["flat"]) { [unowned self] in
            if let name = self.suggestedName { Form.setText(self.aliasField, name) }
        }
        useSuggestion.tooltip("Name from the account's TzProfile")
        Form.addSuffix(useSuggestion, to: aliasField)
        addressField = Form.entry("Address (tz1… or KT1…)", monospaced: true,
                                  onChange: { [unowned self] in self.addressChanged() },
                                  onSubmit: { [unowned self] in if self.canAdd { self.add() } })
        let form = Form.group([
            aliasField, addressField, Form.labeled("Preview", content: preview),
            Form.note("This only records the address. You can watch its balance and send to it, but not spend from it.").row,
        ])
        content.setChildren([Sheet.title("Add address"), form])
        addButton = button("Add", role: .prominent, isDefault: true) { [unowned self] in self.add() }
        setButtons([cancelButton(), addButton])
        focus(aliasField)
        addressChanged()
    }

    private var trimmedAddress: Address { Address(Form.text(addressField).trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var addressLooksValid: Bool { trimmedAddress.isValidAccount }
    private var trimmedAlias: String { Form.text(aliasField).trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool { !trimmedAlias.isEmpty && addressLooksValid && !isAdding }

    private func update() {
        addButton.isSensitive = canAdd
        if let suggestedName, suggestedName != trimmedAlias {
            gtk_button_set_label(useSuggestion.as(), "Use “\(suggestedName)”")
            useSuggestion.isVisible = true
        } else {
            useSuggestion.isVisible = false
        }
    }

    private func updatePreview() {
        let address = trimmedAddress
        if addressLooksValid {
            var lines = [UI.label(address.shortened(), classes: ["address"])]
            if let suggestedName { lines.append(UI.label(suggestedName)) }
            lines += previewDomains.map { UI.label($0, classes: ["dim-label"]) }
            if let scheme = address.scheme {
                lines.append(UI.label(scheme.displayName, classes: ["dim-label", "caption"]))
            } else if address.isContract {
                lines.append(UI.label("Smart contract", classes: ["dim-label", "caption"]))
            }
            preview.setChildren([AccountAvatarView(address: address, size: 32).root, UI.vbox(spacing: 2, lines)])
        } else if Form.text(addressField).isEmpty {
            preview.setChildren([UI.label("Paste or type an address", classes: ["dim-label"])])
        } else {
            preview.setChildren([UI.image(icon: "dialog-warning-symbolic"), UI.label("Not a valid Tezos address", classes: ["dim-label"])])
        }
    }

    /// `.task(id: address)`: look the address's names up, a moment after typing stops.
    private func addressChanged() {
        lookup?.cancel()
        previewDomains = []
        suggestedName = nil
        updatePreview()
        update()
        guard addressLooksValid else { return }
        let address = trimmedAddress
        lookup = Task { [weak self, model] in
            try? await Task.sleep(for: .milliseconds(300))  // debounce typing
            guard !Task.isCancelled else { return }
            async let domains = model.domainNames(for: address)
            async let profile = model.profileName(for: address)
            let (foundDomains, foundName) = await (domains, profile)
            guard let self, !Task.isCancelled else { return }
            self.previewDomains = foundDomains
            self.suggestedName = foundName
            // Offer the TzProfiles name as the alias when the user has not typed one yet.
            if let foundName, self.trimmedAlias.isEmpty { Form.setText(self.aliasField, foundName) }
            self.updatePreview()
            self.update()
        }
    }

    private func add() {
        setError(nil)
        isAdding = true
        update()
        let alias = Form.text(aliasField), address = Form.text(addressField)
        Task {
            defer { isAdding = false; update() }
            do {
                try await model.addWatchOnlyWallet(alias: alias, address: address)
                dismiss()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() { lookup?.cancel() }
}
