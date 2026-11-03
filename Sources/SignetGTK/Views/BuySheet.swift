import CAdwaita
import Foundation

/// Buy tez through an on-ramp picked from the dropdown at the top of the sheet (the choice is
/// remembered). With a widget provider Signet pre-fills (and, when it can sign, pre-validates)
/// the account's address, then shows the provider's widget right here (`BuyWebView`, WebKitGTK);
/// the purchase, identity checks and payment are all the provider's, and the tez land in the
/// account. With an exchange (Coinbase, Kraken) or Transak's site it shows the address to paste
/// and opens the page in the browser. The GTK counterpart of upstream's `Views/BuySheet.swift`.
@MainActor
final class BuySheet: Sheet {
    enum Step: Equatable { case prepare, widget(URL) }

    private var step: Step = .prepare
    private var webView: BuyWebView?
    private let busyLabel = UI.label(classes: ["dim-label"])
    private let busySpinner = Widget(gtk_spinner_new()!)
    private var provider: BuyProvider { BuyProvider(rawValue: UserDefaults.standard.string(forKey: BuyProvider.key) ?? "") ?? .default }
    private var fiats: [String] = []
    private var isWorking = false
    private let wallet: Wallet?
    private let body = UI.vbox(spacing: 0)
    private var providerPicker: Widget!
    private var fiatPicker: Widget?
    private var passphraseField: Widget!

    init(model: WalletViewModel) {
        wallet = model.selectedWallet
        super.init(model: model, width: 560)
        let header = Sheet.accountTitle("Buy tez", wallet: wallet).root
        // While the widget is up: a spinner while it loads, and whose widget it is.
        let loading = UI.hbox(spacing: 8, [busySpinner, busyLabel]).align(v: GTK_ALIGN_CENTER)
        content.setChildren([UI.hbox(spacing: 12, [header.expand(h: true), loading]), body])
        passphraseField = Form.password("Password for “\(wallet?.alias ?? "")”", onChange: { [unowned self] in self.updateButtons() })
        let providers = BuyProvider.allCases
        providerPicker = Form.picker("Provider", options: providers.map(\.title), selected: providers.firstIndex(of: provider) ?? 0) { [unowned self] in
            let index = Form.selected(self.providerPicker)
            guard providers.indices.contains(index), providers[index] != self.provider else { return }
            UserDefaults.standard.set(providers[index].rawValue, forKey: BuyProvider.key)
            UserDefaults.standard.synchronize()   // written now, not only at a clean exit
            // A new provider starts over: its own currencies, no widget, no stale error.
            self.step = .prepare
            self.webView = nil
            self.setError(nil)
            self.render()
        }
        render()
    }

    private var canSign: Bool { wallet?.keyKind.canSign == true }
    private var needsPassphrase: Bool { wallet?.keyKind == .encrypted }
    private var signsOnLedger: Bool { wallet?.keyKind == .ledger }

    private func render() {
        switch (provider.usesWidget, step) {
        case (false, _): body.setChildren([exchange()])
        case (true, .prepare): body.setChildren([prepare()])
        case (true, .widget(let url)): body.setChildren([widget(url)])
        }
        updateLoading()
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
            rows.append(Form.note("Signet holds no key for this address, so \(provider.title) will ask you to confirm it in the widget.").row)
        }
        rows.append(Form.note("\(provider.summary) Everything in the next step runs on \(provider.title)'s site, shown inside Signet.").row)
        return Form.group(rows)
    }

    // MARK: Widget

    private let originIcon = UI.image(icon: "channel-secure-symbolic")
    private let originHost = UI.label(classes: ["address", "dim-label"])
    private let loadErrorRow = UI.hbox(spacing: 6)

    private func widget(_ url: URL) -> Widget {
        let view = webView ?? BuyWebView(url: url, provider: provider)
        webView = view
        view.onChange = { [weak self] in self?.updateLoading() }
        view.root.size(height: 620).expand(h: true).classes("buy-web-view")
        gtk_widget_set_overflow(view.root.pointer, GTK_OVERFLOW_HIDDEN)
        let origin = UI.hbox(spacing: 6, [originIcon, originHost])
        origin.tooltip("Only \(provider.title)'s own HTTPS pages can show here; other sites open in your browser.")
        return UI.vbox(spacing: 8, [
            origin, view.root, loadErrorRow,
            UI.label("When the purchase is done the balance refreshes on the next block.", classes: ["dim-label", "caption"], wrap: true),
        ])
    }

    /// The origin line, the load error and the spinner follow the web view.
    private func updateLoading() {
        guard let webView, case .widget(let url) = step else {
            busySpinner.isVisible = false
            busyLabel.isVisible = false
            return
        }
        let shown = webView.currentURL ?? url
        let trusted = BuyWebView.isTrusted(shown, provider: provider)
        gtk_image_set_from_icon_name(originIcon.opaque, trusted ? "channel-secure-symbolic" : "channel-insecure-symbolic")
        originIcon.setClass("dim-label", trusted)
        originIcon.setClass("warning-text", !trusted)
        UI.setText(originHost, shown.host() ?? "")
        if let error = webView.loadError {
            loadErrorRow.setChildren([UI.image(icon: "dialog-warning-symbolic").align(v: GTK_ALIGN_START),
                                      UI.label("The widget could not load: \(error)", wrap: true).expand(h: true)])
            loadErrorRow.classes("warning-text")
            loadErrorRow.isVisible = true
        } else {
            loadErrorRow.isVisible = false
        }
        busySpinner.isVisible = webView.isLoading
        webView.isLoading ? gtk_spinner_start(busySpinner.opaque) : gtk_spinner_stop(busySpinner.opaque)
        UI.setText(busyLabel, provider.title)
        busyLabel.isVisible = true
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
            switch step {
            case .prepare:
                let next = button("Continue", role: .prominent, isDefault: true) { [unowned self] in self.start() }
                next.isSensitive = !isWorking && !(needsPassphrase && Form.text(passphraseField).isEmpty)
                setButtons([cancelButton(), next])
            case .widget:
                setButtons([button("Open in browser instead") { [unowned self] in self.openInBrowser() },
                            button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
            }
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
                let url = try await model.buyURL(provider: provider, fiat: fiat, passphrase: passphrase, embedded: true, dark: dark)
                Form.clear(passphraseField)
                step = .widget(url)
                render()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    /// The same session as a direct link; the signed proof is reused so nothing is asked twice.
    private func openInBrowser() {
        guard case .widget(let url) = step else { return }
        UI.open(provider.browserURL(from: url), from: content)
    }

    override func closed() { Form.clear(passphraseField) }
}
