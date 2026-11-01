import CAdwaita
import Foundation

/// A sheet: what SwiftUI's `.sheet` shows, here an `AdwDialog` over the window. Each upstream
/// sheet is a subclass that fills `content` (title, form, notes) and `buttons`, and reads its
/// own state back from the widgets when something changes.
///
/// `WalletHomeView` presents a sheet when its `isPresenting…` flag rises and lowers the flag when
/// the dialog closes, however it was closed (Escape, Cancel, or the sheet's `dismiss()`).
@MainActor
class Sheet {
    let model: WalletViewModel
    let dialog: Widget
    /// The sheet's body, top to bottom; `.padding(20)` and `spacing: 16` as upstream's sheets.
    let content = UI.vbox(spacing: 16)
    /// The red line above the buttons (`if let errorMessage { Text(errorMessage) }`).
    let errorLabel = UI.label(classes: ["error-message"], wrap: true)
    /// The bottom row: leading status (a spinner and a line of text), then the buttons.
    let status = UI.hbox(spacing: 8)
    let buttons = UI.hbox(spacing: 8)
    private let spinner = Widget(gtk_spinner_new()!)
    private let statusText = UI.label(classes: ["dim-label"])
    /// Run once the dialog has closed.
    var onClosed: (@MainActor () -> Void)?
    var trackers: [Tracker] = []

    init(model: WalletViewModel, width: Int32 = 480) {
        self.model = model
        dialog = Widget(adw_dialog_new()!)
        adw_dialog_set_content_width(dialog.as(), width)
        // Fit the content as it changes from step to step, smaller as well as larger.
        adw_dialog_set_follows_content_size(dialog.as(), 1)
        errorLabel.isVisible = false
        status.setChildren([spinner, statusText])
        status.isVisible = false
        let bottom = UI.hbox(spacing: 8, [status, UI.hspacer(), buttons])
        // `.padding(20).frame(width:)`: the width includes the padding.
        let column = UI.vbox(spacing: 16, [content, errorLabel, bottom]).margins(20).size(width: width - 40)
        // A sheet taller than the window scrolls rather than being cut off.
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(scroller.opaque, 1)
        gtk_scrolled_window_set_child(scroller.opaque, column.pointer)
        adw_dialog_set_child(dialog.as(), scroller.pointer)
        dialog.retain(self, key: "signet-sheet")
        Signals.connect(dialog, "closed") { [weak self] in
            guard let self else { return }
            self.closed()
            self.onClosed?()
        }
    }

    /// Called when the dialog has gone, before `onClosed`: wipe anything secret here.
    func closed() {}

    func present(over parent: Widget) {
        adw_dialog_present(dialog.as(), parent.pointer)
        // With no field focused, Return still reaches the default button.
        if adw_dialog_get_focus(dialog.as()) == nil, let button = adw_dialog_get_default_widget(dialog.as()) {
            adw_dialog_set_focus(dialog.as(), button)
        }
    }

    /// `@Environment(\.dismiss)`.
    func dismiss() { adw_dialog_force_close(dialog.as()) }

    /// Whether Escape may close the sheet (`.interactiveDismissDisabled()` upstream when false).
    var canClose: Bool {
        get { adw_dialog_get_can_close(dialog.as()) != 0 }
        set { adw_dialog_set_can_close(dialog.as(), newValue ? 1 : 0) }
    }

    func setError(_ message: String?) {
        UI.setText(errorLabel, message ?? "")
        errorLabel.isVisible = message != nil
    }

    /// The spinner and its line at the bottom left (`ProgressView(); Text("Generating key…")`).
    func setBusy(_ text: String?, spinning: Bool = true) {
        status.isVisible = text != nil
        spinner.isVisible = spinning
        spinning && text != nil ? gtk_spinner_start(spinner.opaque) : gtk_spinner_stop(spinner.opaque)
        UI.setText(statusText, text ?? "")
    }

    /// The sheet's heading (`Text(…).font(.title2.weight(.semibold))`).
    static func title(_ text: String) -> Widget { UI.label(text, classes: ["title-2"], wrap: true) }

    /// A heading with the account's avatar and its alias and address beneath, as the account
    /// sheets (Export, Forget, Remember) start.
    static func accountTitle(_ text: String, wallet: Wallet?) -> (root: Widget, title: Widget) {
        let title = Sheet.title(text)
        var column = [title]
        if let wallet { column.append(UI.label("\(wallet.alias)  \(wallet.address.shortened())", classes: ["dim-label"])) }
        var row: [Widget] = []
        if let wallet { row.append(AccountAvatarView(address: wallet.address, size: 40).root) }
        row.append(UI.vbox(spacing: 2, column).align(v: GTK_ALIGN_CENTER))
        return (UI.hbox(spacing: 12, row), title)
    }

    // MARK: Buttons

    enum Role { case normal, prominent, destructive, cancel }

    /// A bottom-row button. `.prominent` and `.destructive` are `.borderedProminent`; the one
    /// marked `isDefault` answers Return (`.keyboardShortcut(.defaultAction)`).
    @discardableResult
    func button(_ title: String, role: Role = .normal, isDefault: Bool = false, action: @escaping @MainActor () -> Void) -> Widget {
        let classes: [String] = switch role {
        case .prominent: ["suggested-action"]
        case .destructive: ["destructive-action"]
        case .normal, .cancel: []
        }
        let button = UI.button(title, classes: classes, action: action)
        if isDefault { adw_dialog_set_default_widget(dialog.as(), button.pointer) }
        return button
    }

    /// Cancel: closes the sheet (`.keyboardShortcut(.cancelAction)`; Escape does the same).
    func cancelButton(_ title: String = "Cancel") -> Widget {
        button(title, role: .cancel) { [weak self] in self?.dismiss() }
    }

    func setButtons(_ list: [Widget]) { buttons.setChildren(list) }

    func focus(_ widget: Widget) { adw_dialog_set_focus(dialog.as(), widget.pointer) }

    /// A coloured box of text with an icon, as upstream's warning panels
    /// (`.padding(12).background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))`).
    static func banner(_ text: String, icon: String = "dialog-warning-symbolic", style: String = "warning") -> Widget {
        let label = UI.label(text, wrap: true).expand(h: true)
        return UI.hbox(spacing: 10, [UI.image(icon: icon, pixelSize: 16).align(v: GTK_ALIGN_START), label]).classes("banner-box", style)
    }
}
