import CAdwaita
import Foundation

/// Light, dark, or follow the desktop. Stored in the app's preferences. The GTK counterpart of
/// upstream's `Services/Appearance.swift`: the same cases, key and titles, applied through
/// libadwaita's style manager instead of `NSApp.appearance`.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "OS"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var stored: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    /// Applies to the whole app; `.system` follows the desktop's preference.
    @MainActor
    func apply() {
        let scheme: AdwColorScheme = switch self {
        case .system: ADW_COLOR_SCHEME_DEFAULT
        case .light: ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: ADW_COLOR_SCHEME_FORCE_DARK
        }
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), scheme)
    }
}
