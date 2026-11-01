import CAdwaita
import Foundation

/// Window actions (`win.<name>`): what menu items and keyboard shortcuts trigger. Plain actions
/// run a closure; choice actions carry a string and keep the current choice as their state, so a
/// menu shows it as a radio item.
@MainActor
final class Actions {
    private let map: OpaquePointer   // GActionMap
    private var actions: [String: OpaquePointer] = [:]   // GSimpleAction

    private final class Handler {
        let run: @MainActor (String?) -> Void
        init(_ run: @escaping @MainActor (String?) -> Void) { self.run = run }
    }

    init(window: Widget) { map = window.opaque }

    func add(_ name: String, _ run: @escaping @MainActor () -> Void) {
        install(name, g_simple_action_new(name, nil)!) { _ in run() }
    }

    /// An action whose parameter is a string, its state the current choice.
    func addChoice(_ name: String, current: String, _ run: @escaping @MainActor (String) -> Void) {
        let type = g_variant_type_new("s")
        defer { g_variant_type_free(type) }
        install(name, g_simple_action_new_stateful(name, type, g_variant_new_string(current))!) { value in
            if let value { run(value) }
        }
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        guard let action = actions[name] else { return }
        g_simple_action_set_enabled(action, enabled ? 1 : 0)
    }

    func setChoice(_ name: String, _ current: String) {
        guard let action = actions[name] else { return }
        g_simple_action_set_state(action, g_variant_new_string(current))
    }

    private func install(_ name: String, _ action: OpaquePointer, _ run: @escaping @MainActor (String?) -> Void) {
        let box = Unmanaged.passRetained(Handler(run)).toOpaque()
        let handler: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, parameter, data in
            let handler = Unmanaged<Handler>.fromOpaque(data!).takeUnretainedValue()
            let value = parameter.map { String(cString: g_variant_get_string($0, nil)) }
            MainActor.assumeIsolated { handler.run(value) }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(action), "activate", unsafeBitCast(handler, to: GCallback.self), box, { data, _ in
            Unmanaged<Handler>.fromOpaque(data!).release()
        }, GConnectFlags(rawValue: 0))
        g_action_map_add_action(map, action)
        actions[name] = action
        g_object_unref(UnsafeMutableRawPointer(action))
    }
}

/// A menu model built in Swift: items in sections, sections separated by lines.
@MainActor
final class MenuBuilder {
    nonisolated(unsafe) let menu = g_menu_new()!
    private var section: OpaquePointer? = nil

    /// Starts a new section, optionally with a heading.
    @discardableResult func section(_ heading: String? = nil) -> MenuBuilder {
        let next = g_menu_new()!
        g_menu_append_section(menu, heading, UnsafeMutablePointer<GMenuModel>(next))
        g_object_unref(UnsafeMutableRawPointer(next))
        section = next
        return self
    }

    @discardableResult func item(_ label: String, action: String) -> MenuBuilder {
        g_menu_append(current, label, "win.\(action)")
        return self
    }

    /// A radio item: checked while the action's state equals `value`.
    @discardableResult func choice(_ label: String, action: String, value: String) -> MenuBuilder {
        let item = g_menu_item_new(label, nil)!
        g_menu_item_set_action_and_target_value(item, "win.\(action)", g_variant_new_string(value))
        g_menu_append_item(current, item)
        g_object_unref(UnsafeMutableRawPointer(item))
        return self
    }

    private var current: OpaquePointer {
        if let section { return section }
        return self.section().section!
    }

    var model: UnsafeMutablePointer<GMenuModel> { UnsafeMutablePointer<GMenuModel>(menu) }

    deinit { g_object_unref(UnsafeMutableRawPointer(menu)) }
}

@MainActor
enum MenuButtons {
    /// A borderless button that opens `menu`, showing `content`.
    static func make(content: Widget, classes: [String] = []) -> Widget {
        let button = Widget(gtk_menu_button_new()!)
        gtk_menu_button_set_child(button.opaque, content.pointer)
        gtk_menu_button_set_has_frame(button.opaque, 0)
        for name in classes { button.classes(name) }
        return button
    }

    static func make(icon: String, tooltip: String) -> Widget {
        let button = Widget(gtk_menu_button_new()!)
        gtk_menu_button_set_icon_name(button.opaque, icon)
        gtk_menu_button_set_has_frame(button.opaque, 0)
        button.tooltip(tooltip).accessibleLabel(tooltip)
        return button
    }

    static func setMenu(_ button: Widget, _ menu: MenuBuilder) {
        gtk_menu_button_set_menu_model(button.opaque, menu.model)
    }
}
