import CAdwaita
import Foundation

/// Records an existing multisig by address, once the chain confirms it is the generic multisig
/// and one of our accounts is a signer. The GTK counterpart of upstream's
/// `Views/AddMultisigSheet.swift`.
@MainActor
final class AddMultisigSheet: Sheet {
    private var info: MultisigInfo?
    private var lookupError: String?
    private var isAdding = false
    private var lookup: Task<Void, Never>?
    private var aliasField: Widget!
    private var addressField: Widget!
    private let contractBox = UI.vbox(spacing: 4)
    private var addButton: Widget!

    init(model: WalletViewModel) {
        super.init(model: model, width: 520)
        aliasField = Form.entry("Name (e.g. treasury)", onChange: { [unowned self] in self.update() })
        addressField = Form.entry("Contract address (KT1…)", monospaced: true, onChange: { [unowned self] in self.addressChanged() })
        let form = Form.group([
            aliasField, addressField, Form.labeled("Contract", content: contractBox),
            Form.note("Only multisigs that one of your accounts can sign for can be added.").row,
        ])
        content.setChildren([Sheet.title("Add multisig"), form])
        addButton = button("Add", role: .prominent, isDefault: true) { [unowned self] in Task { await self.add() } }
        setButtons([cancelButton(), addButton])
        focus(aliasField)
        addressChanged()
    }

    private var address: String { Form.text(addressField) }
    private var trimmedAddress: Address { Address(address.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var addressLooksValid: Bool { trimmedAddress.isContract && trimmedAddress.isValidAccount }
    private var members: [Wallet] { info?.members(among: model.wallets) ?? [] }
    private var canAdd: Bool {
        !Form.text(aliasField).trimmingCharacters(in: .whitespaces).isEmpty && info?.isGenericMultisig == true && !members.isEmpty && !isAdding
    }

    private func update() {
        addButton.isSensitive = canAdd
        if let info {
            if info.isGenericMultisig {
                var lines = [UI.label("\(info.threshold) of \(info.keys.count) signatures · \(AssetBalance.format(info.balance, symbol: "tz"))", xalign: 1)]
                for key in info.keys {
                    if let mine = model.wallets.first(where: { $0.publicKey == key }) {
                        lines.append(UI.hbox(spacing: 4, [UI.image(icon: "object-select-symbolic", pixelSize: 12), UI.label("\(mine.alias) (yours)")]).align(h: GTK_ALIGN_END))
                    } else {
                        lines.append(UI.label(key.prefix(14) + "…", classes: ["address", "dim-label"], xalign: 1))
                    }
                }
                if members.isEmpty {
                    lines.append(UI.label("None of your accounts is a signer", classes: ["warning-text"], xalign: 1))
                }
                contractBox.setChildren(lines)
            } else {
                contractBox.setChildren([UI.label("Not an octez-client multisig", classes: ["warning-text"], xalign: 1)])
            }
        } else if let lookupError {
            contractBox.setChildren([UI.label(lookupError, classes: ["dim-label"], wrap: true, xalign: 1)])
        } else if addressLooksValid {
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            contractBox.setChildren([spinner.align(h: GTK_ALIGN_END)])
        } else {
            contractBox.setChildren([UI.label(address.isEmpty ? "Paste the multisig's address" : "Not a contract address", classes: ["dim-label"], xalign: 1)])
        }
    }

    /// `.task(id: address)`.
    private func addressChanged() {
        lookup?.cancel()
        info = nil; lookupError = nil
        update()
        guard addressLooksValid else { return }
        let address = trimmedAddress
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do { info = try await model.multisigInfo(MultisigContract(alias: "", address: address)) } catch { lookupError = error.localizedDescription }
            guard !Task.isCancelled else { return }
            update()
        }
    }

    private func add() async {
        setError(nil)
        isAdding = true
        update()
        defer { isAdding = false; update() }
        do { _ = try await model.addMultisig(alias: Form.text(aliasField), address: address); dismiss() } catch { setError(error.localizedDescription) }
    }

    override func closed() { lookup?.cancel() }
}
