import CAdwaita
import Foundation

/// One text setting with its error line and Use Default / Apply buttons, as a form row. The GTK
/// counterpart of upstream's `SettingField` in `Views/NetworkSettingsControls.swift` (its
/// `SectionHeader` is the heading and ⓘ tooltip the sheets build for themselves).
@MainActor
final class SettingField {
    let root: Widget
    private let entry = Widget(gtk_entry_new()!)
    private let errorLabel = UI.label(classes: ["error-text"], wrap: true, xalign: 1)
    private let useDefaultButton: Widget
    private let applyButton: Widget
    private let current: @MainActor () -> String
    private let defaultValue: String
    /// Applies the text; false when it was refused.
    private let apply: @MainActor (String) -> Bool
    private let problem: @MainActor (String) -> String
    private var tracker: Tracker?

    init(title: String, current: @escaping @MainActor () -> String, defaultValue: String, prompt: String, monospaced: Bool = false,
         apply: @escaping @MainActor (String) -> Bool, problem: @escaping @MainActor (String) -> String, useDefault: @escaping @MainActor () -> Void) {
        self.current = current
        self.defaultValue = defaultValue
        self.apply = apply
        self.problem = problem
        if monospaced { entry.classes("monospace") }
        PasswordEntry.setPlaceholder(entry, prompt)
        errorLabel.isVisible = false
        useDefaultButton = UI.button(defaultValue.isEmpty ? "Clear" : "Use Default") {}
        applyButton = UI.button("Apply") {}
        let buttons = UI.hbox(spacing: 8, [useDefaultButton, applyButton]).align(h: GTK_ALIGN_END)
        root = Form.stacked(title, below: [entry, errorLabel, buttons])
        root.retain(self, key: "signet-setting-field")
        Signals.connect(useDefaultButton, "clicked") { [unowned self] in useDefault(); self.setError(nil) }
        Signals.connect(applyButton, "clicked") { [unowned self] in self.submit() }
        Signals.connect(entry, "activate") { [unowned self] in self.submit() }
        Signals.connect(entry, "changed") { [unowned self] in self.updateButtons() }
        // `.onAppear(perform: sync)` and `.onChange(of: current) { sync() }`.
        tracker = Tracker { [unowned self] in self.sync() }
    }

    private var text: String { String(cString: gtk_editable_get_text(entry.opaque)) }

    private func sync() {
        gtk_editable_set_text(entry.opaque, current())
        setError(nil)
    }

    private func updateButtons() {
        useDefaultButton.isSensitive = current() != defaultValue
        applyButton.isSensitive = text.trimmingCharacters(in: .whitespacesAndNewlines) != current()
    }

    private func setError(_ message: String?) {
        UI.setText(errorLabel, message ?? "")
        errorLabel.isVisible = message != nil
        updateButtons()
    }

    private func submit() {
        setError(apply(text) ? nil : problem(text))
    }
}
