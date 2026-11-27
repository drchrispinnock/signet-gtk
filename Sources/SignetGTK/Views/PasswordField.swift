import CAdwaita
import Foundation

/// Upstream's `PasswordField`: the password field of a sheet that signs with an encrypted key,
/// or, while a password for that key is remembered (Settings > Passwords), a line saying until
/// when with a Forget button that brings the field back. It is two rows, put in the form
/// together (`rows`), of which it shows one: `entry` (an `AdwPasswordEntryRow`) or `remembered`.
/// Both stay hidden while the wallet is not encrypted or the sheet hides the field (`isShown`).
/// `onChange` runs on every edit and whenever a password is remembered or forgotten, so the
/// sheet can recheck its buttons (`model.needsPassphrase(for:)` changes with it).
@MainActor
final class PasswordField {
    let entry: Widget
    let remembered: Widget
    var rows: [Widget] { [entry, remembered] }

    private let model: WalletViewModel
    var label: String? { didSet { update() } }
    private let rememberedLabel = UI.label(classes: ["dim-label"])
    private var tracker: Tracker?
    /// Runs on every edit and whenever the remembered password appears or goes.
    var onChange: (@MainActor () -> Void)?

    /// The account whose password this is; the title follows it.
    var wallet: Wallet? { didSet { update() } }
    /// Whether the sheet wants the field at all (a step or direction that signs).
    var isShown = true { didSet { update() } }

    init(model: WalletViewModel, wallet: Wallet?, label: String? = nil,
         onChange: (@MainActor () -> Void)? = nil, onSubmit: (@MainActor () -> Void)? = nil) {
        self.model = model
        self.wallet = wallet
        self.label = label
        self.onChange = onChange
        entry = Form.password("", onSubmit: onSubmit)
        let key = UI.image(icon: "dialog-password-symbolic", pixelSize: 16).classes("dim-label")
        let forgetButton = UI.button("Forget", classes: ["flat"]) {}
        remembered = Form.labeled("", content: UI.hbox(spacing: 8, [key, rememberedLabel, forgetButton]))
        Signals.connect(forgetButton, "clicked") { [weak self] in
            guard let self, let wallet = self.wallet else { return }
            self.model.forgetRememberedPassphrase(for: wallet)
        }
        Signals.connect(entry, "changed") { [weak self] in self?.onChange?() }
        var first = true
        tracker = Tracker { [weak self] in
            guard let self else { return }
            _ = self.model.passphraseCacheRevision
            self.update()
            if !first { self.onChange?() }
            first = false
        }
    }

    /// The typed password; empty while a remembered one stands in.
    var text: String { Form.text(entry) }
    func clear() { Form.clear(entry) }

    /// Whether the typed password is still needed: an encrypted key with none remembered.
    var isNeeded: Bool { model.needsPassphrase(for: wallet) }

    private func update() {
        let title = label ?? "Password for “\(wallet?.alias ?? "")”"
        adw_preferences_row_set_title(entry.as(), title)
        adw_preferences_row_set_title(remembered.as(), title)
        let encrypted = isShown && wallet?.keyKind == .encrypted
        let expires = wallet.flatMap { model.rememberedPassphraseExpiry(for: $0) }
        if let expires { UI.setText(rememberedLabel, "Remembered until \(expires.formatted(date: .omitted, time: .shortened))") }
        entry.isVisible = encrypted && expires == nil
        remembered.isVisible = encrypted && expires != nil
    }
}
