import CAdwaita
import Foundation

/// Asks the current testnet's faucet to send tez to the selected wallet. The GTK counterpart of
/// upstream's `Views/FaucetSheet.swift`.
@MainActor
final class FaucetSheet: Sheet {
    private var amountField: Widget!
    private let limitsLabel = UI.label(classes: ["dim-label"])
    private let statusBox = UI.hbox(spacing: 8)
    private var requestButton: Widget!
    private var limits: (min: Double, max: Double)?

    init(model: WalletViewModel) {
        super.init(model: model, width: 460)
        var rows: [Widget] = []
        if let wallet {
            rows.append(Form.labeled("To", content: UI.hbox(spacing: 8, [
                AccountAvatarView(address: wallet.address, size: 24).root, UI.label(wallet.alias),
                UI.label(wallet.address.shortened(), classes: ["address", "dim-label"]),
            ])))
        }
        rows.append(Form.labeled("Faucet", value: model.network.faucetURL?.host() ?? "").row)
        amountField = Form.entry("Amount (tz)", text: "\(Int(WalletViewModel.faucetAmountTez))", monospaced: true,
                                 onChange: { [unowned self] in self.update() },
                                 onSubmit: { [unowned self] in if self.amount != nil, !self.isBusy { self.request() } })
        limitsLabel.isVisible = false
        Form.addSuffix(limitsLabel, to: amountField)
        rows.append(amountField)
        rows.append(Form.note(model.network.faucetKind == .teztnets
            ? "The faucet asks for a small proof of work before it pays out; Signet solves it for you. Test tez have no value."
            : "The faucet pays out on request. Test tez have no value.").row)
        content.setChildren([Sheet.title("Get test tez"), Form.group(rows), statusBox])
        requestButton = button("Request", role: .prominent, isDefault: true) { [unowned self] in self.request() }
        trackers.append(Tracker { [unowned self] in self.update() })

        // `.task`: the faucet's limits.
        Task { [weak self, network = model.network] in
            guard let service = FaucetService(network: network), let info = try? await service.info(), let self else { return }
            self.limits = (info.minTez, info.maxTez)
            UI.setText(self.limitsLabel, "\(Int(info.minTez)) to \(Int(info.maxTez))")
            self.limitsLabel.isVisible = true
            if WalletViewModel.faucetAmountTez > info.maxTez { Form.setText(self.amountField, "\(Int(info.maxTez))") }
            self.update()
        }
    }

    private var wallet: Wallet? { model.selectedWallet }
    private var amount: Double? {
        guard let value = Double(Form.text(amountField).trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        if let limits, value < limits.min || value > limits.max { return nil }
        return value
    }
    private var isBusy: Bool {
        switch model.faucetStatus {
        case .solving, .sent: true
        default: false
        }
    }

    private func update() {
        updateStatus()
        var list: [Widget] = []
        if case .solving = model.faucetStatus {
            list.append(button("Cancel") { [model] in model.cancelFaucetRequest() })
        }
        list.append(cancelButton(isBusy ? "Close" : "Done"))
        requestButton.isSensitive = amount != nil && !isBusy && wallet != nil
        list.append(requestButton)
        setButtons(list)
    }

    private func updateStatus() {
        switch model.faucetStatus {
        case .idle:
            statusBox.setChildren([])
        case .solving(let done, let total):
            let bar = Widget(gtk_progress_bar_new()!).size(width: 160).align(v: GTK_ALIGN_CENTER)
            gtk_progress_bar_set_fraction(bar.opaque, Double(done) / Double(max(total, 1)))
            statusBox.setChildren([bar, UI.label("Solving faucet challenge \(min(done + 1, total)) of \(total)…", classes: ["dim-label"])])
        case .sent(let hash):
            let spinner = Widget(gtk_spinner_new()!)
            gtk_spinner_start(spinner.opaque)
            statusBox.setChildren([spinner, UI.label("Sent, waiting for the next block…", classes: ["dim-label"]), hashLabel(hash)])
        case .received(let hash):
            statusBox.setChildren([UI.image(icon: "object-select-symbolic").classes("success-icon"), UI.label("Received. Balance updated."), hashLabel(hash)])
        case .failed(let message):
            statusBox.setChildren([UI.image(icon: "dialog-warning-symbolic").classes("error-text").align(v: GTK_ALIGN_START),
                                   UI.label(message, classes: ["error-text"], wrap: true).expand(h: true)])
        }
        statusBox.isVisible = gtk_widget_get_first_child(statusBox.pointer) != nil
    }

    private func hashLabel(_ hash: String) -> Widget {
        let label = UI.label(hash, classes: ["address", "caption"]).expand(h: true)
        gtk_label_set_ellipsize(label.opaque, PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_selectable(label.opaque, 1)
        return label
    }

    private func request() {
        guard let amount else { return }
        Task { await model.requestTestTez(amount: amount) }
    }
}
