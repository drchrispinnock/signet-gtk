import CAdwaita
import Foundation
import Observation

// A thin Swift layer over GTK's C API: just enough for the views to read clearly. GTK owns the
// widgets (a parent keeps its children alive); a `Widget` is only a typed handle. Everything
// here runs on the main thread, which is also the main actor's thread (`MainLoop`).

@MainActor
struct Widget {
    let pointer: UnsafeMutablePointer<GtkWidget>

    init(_ raw: UnsafeMutableRawPointer) { pointer = raw.assumingMemoryBound(to: GtkWidget.self) }
    init<T>(_ typed: UnsafeMutablePointer<T>) { self.init(UnsafeMutableRawPointer(typed)) }
    init(_ opaque: OpaquePointer) { self.init(UnsafeMutableRawPointer(opaque)) }

    /// The widget as the GTK type a C function expects (`gtk_box_append(box.as(), …)`).
    func `as`<T>(_: T.Type = T.self) -> UnsafeMutablePointer<T> { UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self) }
    var opaque: OpaquePointer { OpaquePointer(pointer) }
    var raw: gpointer { UnsafeMutableRawPointer(pointer) }

    // MARK: Layout and look

    @discardableResult func classes(_ names: String...) -> Widget {
        for name in names { gtk_widget_add_css_class(pointer, name) }
        return self
    }
    func removeClass(_ name: String) { gtk_widget_remove_css_class(pointer, name) }
    func setClass(_ name: String, _ on: Bool) { on ? gtk_widget_add_css_class(pointer, name) : gtk_widget_remove_css_class(pointer, name) }

    @discardableResult func margins(_ all: Int32) -> Widget { margins(top: all, bottom: all, start: all, end: all) }
    @discardableResult func margins(top: Int32 = 0, bottom: Int32 = 0, start: Int32 = 0, end: Int32 = 0) -> Widget {
        gtk_widget_set_margin_top(pointer, top)
        gtk_widget_set_margin_bottom(pointer, bottom)
        gtk_widget_set_margin_start(pointer, start)
        gtk_widget_set_margin_end(pointer, end)
        return self
    }
    @discardableResult func expand(h: Bool = false, v: Bool = false) -> Widget {
        gtk_widget_set_hexpand(pointer, h ? 1 : 0)
        gtk_widget_set_vexpand(pointer, v ? 1 : 0)
        return self
    }
    @discardableResult func align(h: GtkAlign? = nil, v: GtkAlign? = nil) -> Widget {
        if let h { gtk_widget_set_halign(pointer, h) }
        if let v { gtk_widget_set_valign(pointer, v) }
        return self
    }
    @discardableResult func size(width: Int32 = -1, height: Int32 = -1) -> Widget {
        gtk_widget_set_size_request(pointer, width, height)
        return self
    }
    @discardableResult func tooltip(_ text: String?) -> Widget {
        gtk_widget_set_tooltip_text(pointer, text)
        return self
    }
    var isVisible: Bool {
        get { gtk_widget_get_visible(pointer) != 0 }
        nonmutating set { gtk_widget_set_visible(pointer, newValue ? 1 : 0) }
    }
    var isSensitive: Bool {
        get { gtk_widget_get_sensitive(pointer) != 0 }
        nonmutating set { gtk_widget_set_sensitive(pointer, newValue ? 1 : 0) }
    }

    /// The text screen readers announce for the widget.
    @discardableResult func accessibleLabel(_ text: String) -> Widget {
        let value = UnsafeMutablePointer<GValue>.allocate(capacity: 1)
        value.initialize(to: GValue())
        g_value_init(value, gType(16))   // G_TYPE_STRING
        g_value_set_string(value, text)
        var property = GTK_ACCESSIBLE_PROPERTY_LABEL
        gtk_accessible_update_property_value(OpaquePointer(pointer), 1, &property, value)
        g_value_unset(value)
        value.deallocate()
        return self
    }

    // MARK: Children

    /// Removes every child of a box.
    func removeAllChildren() {
        while let child = gtk_widget_get_first_child(pointer) {
            gtk_box_remove(self.as(), child)
        }
    }

    func append(_ child: Widget) { gtk_box_append(self.as(), child.pointer) }

    /// Replaces a box's children.
    func setChildren(_ children: [Widget]) {
        removeAllChildren()
        for child in children { append(child) }
    }

    // MARK: Keeping Swift objects alive

    /// Keeps `object` alive for as long as the widget lives: how a view's Swift object stays
    /// around while GTK shows what it built.
    func retain(_ object: AnyObject, key: String = "signet-owner") {
        g_object_set_data_full(UnsafeMutablePointer(OpaquePointer(pointer)), key, Unmanaged.passRetained(object).toOpaque()) {
            Unmanaged<AnyObject>.fromOpaque($0!).release()
        }
    }
}

/// `G_TYPE_STRING` (16) and friends are macros over fundamental type numbers.
func gType(_ fundamental: Int32) -> GType { GType(fundamental << G_TYPE_FUNDAMENTAL_SHIFT) }

// MARK: - Builders

@MainActor
enum UI {
    static func vbox(spacing: Int32 = 0, _ children: [Widget] = []) -> Widget {
        let box = Widget(gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing)!)
        for child in children { box.append(child) }
        return box
    }

    static func hbox(spacing: Int32 = 0, _ children: [Widget] = []) -> Widget {
        let box = Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing)!)
        for child in children { box.append(child) }
        return box
    }

    static func label(_ text: String = "", classes: [String] = [], wrap: Bool = false, xalign: Float = 0) -> Widget {
        let label = Widget(gtk_label_new(text)!)
        for name in classes { label.classes(name) }
        gtk_label_set_xalign(label.opaque, xalign)
        if wrap {
            gtk_label_set_wrap(label.opaque, 1)
            gtk_label_set_wrap_mode(label.opaque, PANGO_WRAP_WORD_CHAR)
        }
        return label
    }

    static func setText(_ label: Widget, _ text: String) {
        gtk_label_set_text(label.opaque, text)
    }

    static func separator(vertical: Bool = false) -> Widget {
        Widget(gtk_separator_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)!)
    }

    static func spacer() -> Widget { vbox().expand(h: true, v: true) }

    /// Takes the spare width of a row, and only the width.
    static func hspacer() -> Widget { vbox().expand(h: true) }

    /// `inner` centred in a `size`-square box (drawn round by its CSS class). The box sets its
    /// own expansion, so the inner widget's does not spread to the rows around it.
    static func circle(_ inner: Widget, size: Int32, classes: String...) -> Widget {
        inner.align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER).expand(h: true, v: true)
        let box = vbox(spacing: 0, [inner]).size(width: size, height: size).expand().align(h: GTK_ALIGN_START, v: GTK_ALIGN_CENTER)
        for name in classes { box.classes(name) }
        gtk_widget_set_overflow(box.pointer, GTK_OVERFLOW_HIDDEN)
        return box
    }

    static func image(icon: String, pixelSize: Int32 = 16) -> Widget {
        let image = Widget(gtk_image_new_from_icon_name(icon)!)
        gtk_image_set_pixel_size(image.opaque, pixelSize)
        return image
    }

    /// An image shipped with the app (`Bundle.module`), drawn `pixelSize` square; nil if missing.
    static func resourceImage(_ name: String, _ ext: String, pixelSize: Int32) -> Widget? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { return nil }
        let image = Widget(gtk_image_new_from_file(url.path)!)
        gtk_image_set_pixel_size(image.opaque, pixelSize)
        return image
    }

    static func button(_ title: String, classes: [String] = [], action: @escaping @MainActor () -> Void) -> Widget {
        let button = Widget(gtk_button_new_with_label(title)!)
        for name in classes { button.classes(name) }
        Signals.connect(button, "clicked", action)
        return button
    }

    static func iconButton(_ icon: String, tooltip: String, action: @escaping @MainActor () -> Void) -> Widget {
        let button = Widget(gtk_button_new_from_icon_name(icon)!)
        button.classes("flat").tooltip(tooltip).accessibleLabel(tooltip)
        Signals.connect(button, "clicked", action)
        return button
    }

    /// A button whose content is any widget.
    static func button(content: Widget, classes: [String] = [], action: @escaping @MainActor () -> Void) -> Widget {
        let button = Widget(gtk_button_new()!)
        gtk_button_set_child(button.as(), content.pointer)
        for name in classes { button.classes(name) }
        Signals.connect(button, "clicked", action)
        return button
    }

    /// Runs `action` when the widget is clicked (for labels and other passive widgets).
    static func onClick(_ widget: Widget, _ action: @escaping @MainActor () -> Void) {
        let gesture = gtk_gesture_click_new()!
        Signals.connect(Widget(gesture), "released", action)
        gtk_widget_add_controller(widget.pointer, gesture)
        gtk_widget_set_cursor_from_name(widget.pointer, "pointer")
    }

    static func copyToClipboard(_ text: String, from widget: Widget) {
        gdk_clipboard_set_text(gtk_widget_get_clipboard(widget.pointer), text)
    }
}

// MARK: - Signals

@MainActor
enum Signals {
    private final class Box {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    }

    /// Connects a signal whose handler needs nothing from its arguments (`clicked`, `released`,
    /// `activate`, …). Connected swapped, so the user data comes first whatever the signal's own
    /// arguments are (`released` has three more); GLib passes more than the handler declares,
    /// which C callers may.
    static func connect(_ instance: Widget, _ signal: String, _ action: @escaping @MainActor () -> Void) {
        let box = Unmanaged.passRetained(Box(action)).toOpaque()
        let handler: @convention(c) (gpointer?) -> Void = { data in
            let box = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { box.action() }
        }
        g_signal_connect_data(instance.raw, signal, unsafeBitCast(handler, to: GCallback.self), box, { data, _ in
            Unmanaged<Box>.fromOpaque(data!).release()
        }, G_CONNECT_SWAPPED)
    }
}

// MARK: - Following the model

/// Runs `update` now and again whenever anything observable it read changes, until its owner
/// goes away: the GTK stand-in for a SwiftUI view's `body` being re-evaluated.
@MainActor
final class Tracker {
    private let update: @MainActor () -> Void
    private var scheduled = false

    init(_ update: @escaping @MainActor () -> Void) {
        self.update = update
        run()
    }

    private func run() {
        scheduled = false
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.scheduled else { return }
                self.scheduled = true
                self.run()
            }
        }
    }
}
