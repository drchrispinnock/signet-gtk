import CAdwaita
import Foundation

/// Changes the alias of the selected wallet. The GTK counterpart of upstream's
/// `Views/RenameWalletSheet.swift`.
@MainActor
final class RenameWalletSheet: Sheet {
    private var aliasField: Widget!
    private var syncButton: Widget!
    private var renameButton: Widget!
    private var isSyncing = false

    init(model: WalletViewModel) {
        super.init(model: model, width: 440)
        aliasField = Form.entry("Name", text: model.selectedWallet?.alias ?? "",
                                onChange: { [unowned self] in self.update() },
                                onSubmit: { [unowned self] in if self.canRename { self.rename() } })
        syncButton = UI.button(content: UI.hbox(spacing: 6, [UI.image(icon: "avatar-default-symbolic"), UI.label("Sync with TzProfile")]),
                               classes: ["flat"]) { [unowned self] in self.syncWithProfile() }
        syncButton.tooltip("Fetch the name this address publishes in its TzProfile")
        Form.addSuffix(syncButton, to: aliasField)
        var rows = [aliasField!]
        if let wallet = model.selectedWallet {
            rows.append(Form.labeled("Address", value: wallet.address.shortened(), monospaced: true).row)
        }
        rows.append(Form.note("The alias is renamed in ~/.signet.").row)
        content.setChildren([Sheet.title("Rename account"), Form.group(rows)])

        renameButton = button("Rename", role: .prominent, isDefault: true) { [unowned self] in self.rename() }
        setButtons([cancelButton(), renameButton])
        focus(aliasField)
        update()
    }

    private var trimmedAlias: String { Form.text(aliasField).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canRename: Bool { !trimmedAlias.isEmpty && trimmedAlias != model.selectedWallet?.alias }

    private func update() {
        renameButton.isSensitive = canRename
        syncButton.isSensitive = !isSyncing
    }

    private func syncWithProfile() {
        guard let wallet = model.selectedWallet else { return }
        setError(nil)
        isSyncing = true
        update()
        Task {
            defer { isSyncing = false; update() }
            if let name = await model.profileName(for: wallet.address) {
                Form.setText(aliasField, name)
            } else {
                setError("This address has no TzProfile name.")
            }
        }
    }

    private func rename() {
        setError(nil)
        do {
            try model.renameSelectedWallet(to: trimmedAlias)
            dismiss()
        } catch {
            setError(error.localizedDescription)
        }
    }
}
