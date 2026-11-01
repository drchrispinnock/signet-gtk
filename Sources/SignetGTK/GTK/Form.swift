import CAdwaita
import Foundation

/// SwiftUI's `Form { … }.formStyle(.grouped)` in libadwaita's terms: a boxed list of rows. Text
/// fields are `AdwEntryRow`s, secure fields `AdwPasswordEntryRow`s, toggles `AdwSwitchRow`s,
/// pickers `AdwComboRow`s and `LabeledContent` an `AdwActionRow` with the value at its end. Plain
/// text (the notes upstream puts inside its forms) gets a row of its own so it stays in order.
@MainActor
enum Form {
    static func group(_ rows: [Widget]) -> Widget {
        let list = Widget(gtk_list_box_new()!)
        gtk_list_box_set_selection_mode(list.opaque, GTK_SELECTION_NONE)
        list.classes("boxed-list")
        for row in rows { gtk_list_box_append(list.opaque, row.pointer) }
        return list
    }

    static func append(_ row: Widget, to group: Widget) { gtk_list_box_append(group.opaque, row.pointer) }

    /// Replaces a group's rows.
    static func setRows(_ group: Widget, _ rows: [Widget]) {
        gtk_list_box_remove_all(group.opaque)
        for row in rows { gtk_list_box_append(group.opaque, row.pointer) }
    }

    // MARK: Text

    /// `TextField(title, text:)`. `onChange` runs on every edit, `onSubmit` on Return.
    static func entry(_ title: String, text: String = "", monospaced: Bool = false,
                      onChange: (@MainActor () -> Void)? = nil, onSubmit: (@MainActor () -> Void)? = nil) -> Widget {
        let row = Widget(adw_entry_row_new()!)
        adw_preferences_row_set_title(row.as(), title)
        gtk_editable_set_text(row.opaque, text)
        if monospaced { row.classes("monospace") }
        connect(row, onChange: onChange, onSubmit: onSubmit)
        return row
    }

    /// `SecureField(title, text:)`.
    static func password(_ title: String, onChange: (@MainActor () -> Void)? = nil, onSubmit: (@MainActor () -> Void)? = nil) -> Widget {
        let row = Widget(adw_password_entry_row_new()!)
        adw_preferences_row_set_title(row.as(), title)
        connect(row, onChange: onChange, onSubmit: onSubmit)
        return row
    }

    private static func connect(_ row: Widget, onChange: (@MainActor () -> Void)?, onSubmit: (@MainActor () -> Void)?) {
        if let onChange { Signals.connect(row, "changed", onChange) }
        if let onSubmit {
            adw_entry_row_set_activates_default(row.as(), 0)
            Signals.connect(row, "entry-activated", onSubmit)
        } else {
            adw_entry_row_set_activates_default(row.as(), 1)
        }
    }

    static func text(_ row: Widget) -> String { String(cString: gtk_editable_get_text(row.opaque)) }
    static func setText(_ row: Widget, _ text: String) {
        guard Form.text(row) != text else { return }
        gtk_editable_set_text(row.opaque, text)
    }

    /// Clears a password field (the text is still in GTK's buffer until replaced).
    static func clear(_ row: Widget) { gtk_editable_set_text(row.opaque, "") }

    /// Widgets at the end of an entry row (a button beside the text field).
    static func addSuffix(_ widget: Widget, to row: Widget) {
        widget.align(v: GTK_ALIGN_CENTER)
        adw_entry_row_add_suffix(row.as(), widget.pointer)
    }

    // MARK: Choices

    /// `Toggle(title, isOn:)`.
    static func toggle(_ title: String, isOn: Bool, subtitle: String? = nil, onChange: (@MainActor () -> Void)? = nil) -> Widget {
        let row = Widget(adw_switch_row_new()!)
        adw_preferences_row_set_title(row.as(), title)
        if let subtitle { adw_action_row_set_subtitle(row.as(), subtitle) }
        adw_switch_row_set_active(row.opaque, isOn ? 1 : 0)
        if let onChange { Signals.connect(row, "notify::active", onChange) }
        return row
    }

    static func isOn(_ row: Widget) -> Bool { adw_switch_row_get_active(row.opaque) != 0 }
    static func setOn(_ row: Widget, _ on: Bool) { adw_switch_row_set_active(row.opaque, on ? 1 : 0) }

    /// `Picker(title, selection:)` over `options`, shown by their labels.
    static func picker(_ title: String, options: [String], selected: Int = 0, onChange: (@MainActor () -> Void)? = nil) -> Widget {
        let row = Widget(adw_combo_row_new()!)
        adw_preferences_row_set_title(row.as(), title)
        setOptions(row, options, selected: selected)
        if let onChange { Signals.connect(row, "notify::selected", onChange) }
        return row
    }

    /// Replaces a picker's options, keeping `selected`.
    static func setOptions(_ row: Widget, _ options: [String], selected: Int) {
        var pointers = options.map { strdup($0) }
        pointers.append(nil)
        let list = pointers.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { gtk_string_list_new($0) }
        }
        for pointer in pointers { free(pointer) }
        adw_combo_row_set_model(row.as(), list)
        g_object_unref(UnsafeMutableRawPointer(list))
        adw_combo_row_set_selected(row.as(), guint(max(0, min(selected, options.count - 1))))
    }

    static func selected(_ row: Widget) -> Int {
        let index = adw_combo_row_get_selected(row.as())
        return index == guint(GTK_INVALID_LIST_POSITION) ? -1 : Int(index)
    }

    static func select(_ row: Widget, _ index: Int) {
        guard selected(row) != index else { return }
        adw_combo_row_set_selected(row.as(), guint(index))
    }

    // MARK: Read-only rows

    /// `LabeledContent(title, value:)`: the title at the start, the value at the end.
    static func labeled(_ title: String, value: String, monospaced: Bool = false) -> (row: Widget, value: Widget) {
        let label = UI.label(value, classes: monospaced ? ["address"] : [], wrap: true, xalign: 1)
        gtk_label_set_selectable(label.opaque, 1)
        return (labeled(title, content: label), label)
    }

    /// `LabeledContent(title) { content }`.
    static func labeled(_ title: String, content: Widget) -> Widget {
        let row = Widget(adw_action_row_new()!)
        adw_preferences_row_set_title(row.as(), title)
        content.align(v: GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(row.as(), content.pointer)
        return row
    }

    /// A row of plain text: the notes and warnings upstream writes inside its forms.
    static func note(_ text: String, icon: String? = nil, style: String = "dim-label") -> (row: Widget, label: Widget) {
        let label = UI.label(text, wrap: true).expand(h: true)
        var children = [label]
        if let icon { children.insert(UI.image(icon: icon, pixelSize: 16).align(v: GTK_ALIGN_START), at: 0) }
        let box = UI.hbox(spacing: 8, children).classes(style)
        return (row(box), label)
    }

    /// Any widget as a passive row.
    static func row(_ child: Widget) -> Widget {
        let row = Widget(gtk_list_box_row_new()!)
        gtk_list_box_row_set_activatable(row.as(), 0)
        gtk_list_box_row_set_child(row.as(), child.margins(top: 10, bottom: 10, start: 12, end: 12).pointer)
        return row
    }
}
