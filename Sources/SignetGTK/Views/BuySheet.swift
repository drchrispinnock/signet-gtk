import CAdwaita
import Foundation

/// Buy tez through an on-ramp picked from the dropdown at the top of the sheet (the choice is
/// remembered). The GTK counterpart of upstream's `Views/BuySheet.swift`. With an exchange
/// (Coinbase, Kraken) or Transak's site it shows the address to paste and opens the page in the
/// browser, as upstream does. A widget provider (Mt Pelerin) is prepared the same way, the
/// address pre-filled and, when Signet can sign, pre-validated, but its page opens in the browser
/// as a direct link: the in-app `BuyWebView` (WKWebView) is not ported.
@MainActor
final class BuySheet: Sheet {
    private var provider: BuyProvider { BuyProvider(rawValue: UserDefaults.standard.string(forKey: BuyProvider.key) ?? "") ?? .default }
    private var fiats: [String] = []
    private var isWorking = false
    private let wallet: Wallet?
    private let body = UI.vbox(spacing: 0)
    private var providerPicker: Widget!
    private var fiatPicker: Widget?
    private var passphraseField: Widget!
    private var opened = false

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 560)
        content.setChildren([Sheet.accountTitle("Buy tez", wallet: wallet).root, body])
        passphraseField = Form.password("Password for “\(wallet?.alias ?? "")”", onChange: { [unowned self] in self.updateButtons() })
        let providers = BuyProvider.allCases
        providerPicker = Form.picker("Provider", options: providers.map(\.title), selected: providers.firstIndex(of: provider) ?? 0) { [unowned self] in
            let index = Form.selected(self.providerPicker)
            guard providers.indices.contains(index), providers[index] != self.provider else { return }
            UserDefaults.standard.set(providers[index].rawValue, forKey: BuyProvider.key)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
            // A new provider starts over: its own currencies, no stale error.
            self.opened = false
            self.setError(nil)
            self.render()
        }
        render()
    }

    private var canSign: Bool { wallet?.keyKind.canSign == true }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }

    private func render() {
        body.setChildren([provider.usesWidget ? prepare() : exchange()])
        updateButtons()
    }

    // MARK: Exchange (no widget)

    /// The address to paste as the withdrawal destination, and the exchange's page in the browser.
    private func exchange() -> Widget {
        var rows = [providerPicker!]
        if let wallet {
            let address = UI.label(wallet.address.value, classes: ["address"], xalign: 1)
            gtk_label_set_selectable(address.opaque, 1)
            rows.append(Form.labeled("Send to", content: UI.hbox(spacing: 8, [address, UI.copyButton(tooltip: "Copy address") { wallet.address.value }])))
            if let image = QRCode.image(for: wallet.address.value, size: 160) {
                let code = Widget(gtk_image_new_from_paintable(image.texture)!)
                gtk_image_set_pixel_size(code.opaque, Int32(image.width))
                rows.append(Form.row(UI.vbox(spacing: 0, [code]).classes("qr-box").align(h: GTK_ALIGN_CENTER)))
            }
        }
        rows.append(Form.row(UI.vbox(spacing: 6, [
            UI.label("1. Open \(provider.title) and buy tez (XTZ).", classes: ["dim-label"], wrap: true),
            UI.label("2. \(provider.deliveryStep)", classes: ["dim-label"], wrap: true),
            UI.label("3. The balance here refreshes once the transfer is in a block.", classes: ["dim-label"], wrap: true),
        ])))
        rows.append(Form.note("\(provider.summary) Send tez only; tokens on other networks cannot reach a Tezos address.").row)
        return Form.group(rows)
    }

    // MARK: Widget provider

    private func prepare() -> Widget {
        fiats = provider.fiatCurrencies
        let defaultFiat = provider.defaultFiat()
        let fiat = Form.picker("Pay in", options: fiats, selected: fiats.firstIndex(of: defaultFiat) ?? 0)
        fiatPicker = fiat
        var rows = [providerPicker!, fiat]
        if let wallet {
            let address = UI.label(wallet.address.value, classes: ["address"], xalign: 1)
            gtk_label_set_selectable(address.opaque, 1)
            rows.append(Form.labeled("Deliver to", content: address))
        }
        if needsPassphrase {
            rows.append(passphraseField)
            rows.append(Form.note("Signet signs a short message with this key so \(provider.title) knows the address is yours.").row)
        } else if signsOnLedger {
            rows.append(Form.note("Your Ledger will ask you to sign a short message proving the address is yours.").row)
        } else if !canSign {
            rows.append(Form.note("Signet holds no key for this address, so \(provider.title) will ask you to confirm it on its page.").row)
        }
        rows.append(Form.note("\(provider.summary) The next step opens \(provider.title)'s site in your browser.").row)
        if opened {
            rows.append(Form.note("\(provider.title) is open in your browser. When the purchase is done the balance refreshes on the next block.", icon: "object-select-symbolic").row)
        }
        return Form.group(rows)
    }

    private var fiat: String {
        guard let fiatPicker else { return provider.defaultFiat() }
        let index = Form.selected(fiatPicker)
        return fiats.indices.contains(index) ? fiats[index] : provider.defaultFiat()
    }

    // MARK: Buttons

    private func updateButtons() {
        if isWorking {
            setBusy(signsOnLedger ? "Sign the message on your Ledger…" : "Preparing…")
        } else {
            setBusy(nil)
        }
        if !provider.usesWidget {
            setButtons([cancelButton("Done"), button("Open \(provider.title)", role: .prominent, isDefault: true) { [unowned self] in
                if let page = self.provider.browserPage { UI.open(page, from: self.content) }
            }])
        } else {
            let open = button(opened ? "Open again" : "Continue", role: .prominent, isDefault: true) { [unowned self] in self.start() }
            open.isSensitive = !isWorking && !(needsPassphrase && Form.text(passphraseField).isEmpty)
            setButtons([cancelButton(opened ? "Done" : "Cancel"), open])
        }
    }

    private func start() {
        setError(nil)
        isWorking = true
        updateButtons()
        let (provider, fiat) = (provider, fiat)
        let passphrase = needsPassphrase ? Form.text(passphraseField) : nil
        let dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        Task {
            defer { isWorking = false; updateButtons() }
            do {
                let url = try await model.buyURL(provider: provider, fiat: fiat, passphrase: passphrase, embedded: false, dark: dark)
                UI.open(url, from: content)
                opened = true
                render()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    override func closed() { Form.clear(passphraseField) }
}
