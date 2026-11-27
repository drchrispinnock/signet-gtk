import Foundation
import Observation

/// Settings > Experimental Features, as the views see them. Upstream reads each with
/// `@AppStorage` (`Layer2Branding.key`, `LayerMarks.key`, `ConsolidatedBalances.key`), so a
/// change redraws whatever shows it; here the values are kept in UserDefaults as upstream keeps
/// them and mirrored in this observable object, which views read inside a `Tracker` to be
/// redrawn when Settings changes one.
@MainActor
@Observable
final class Experimental {
    static let shared = Experimental()

    private(set) var branding = Layer2Branding.current()
    private(set) var marks = LayerMarks(rawValue: UserDefaults.standard.string(forKey: LayerMarks.key) ?? "") ?? .logos
    private(set) var consolidates = UserDefaults.standard.bool(forKey: ConsolidatedBalances.key)

    func set(branding: Layer2Branding) {
        guard branding != self.branding else { return }
        store(branding.rawValue, forKey: Layer2Branding.key)
        self.branding = branding
    }

    func set(marks: LayerMarks) {
        guard marks != self.marks else { return }
        store(marks.rawValue, forKey: LayerMarks.key)
        self.marks = marks
    }

    func set(consolidates: Bool) {
        guard consolidates != self.consolidates else { return }
        store(consolidates, forKey: ConsolidatedBalances.key)
        self.consolidates = consolidates
    }

    private func store(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()   // written now, not only at a clean exit
    }
}

extension Layer2Branding {
    /// The file shipped as a resource for `logo` (upstream's asset catalogue images).
    var logoFile: (name: String, ext: String) {
        switch self {
        case .etherlink: ("etherlink-avatar", "svg")
        case .tezosX: ("tezos-x-round", "svg")
        }
    }

    /// The file for `miniLogo`, the 14 to 16 point marks on the tabs.
    var miniLogoFile: (name: String, ext: String) {
        switch self {
        case .etherlink: ("etherlink-avatar", "svg")
        case .tezosX: ("tezos-x-mini", "svg")
        }
    }
}
