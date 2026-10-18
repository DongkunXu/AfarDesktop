import AfarKit
import CoreGraphics
import Foundation
import Observation

/// App settings, stored in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    /// New sessions join the frontmost session window as a tab.
    var openInTabs: Bool {
        didSet { defaults.set(openInTabs, forKey: Keys.openInTabs) }
    }

    /// Render scale for new connections, in percent.
    var defaultRenderScale: Int {
        didSet { defaults.set(defaultRenderScale, forKey: Keys.defaultRenderScale) }
    }

    /// Session windows show the statistics panel.
    var showsStatistics: Bool {
        didSet { defaults.set(showsStatistics, forKey: Keys.showsStatistics) }
    }

    /// The statistics panel as a single line of figures, without graphs.
    var compactStatistics: Bool {
        didSet { defaults.set(compactStatistics, forKey: Keys.compactStatistics) }
    }

    /// Where the statistics panel sits: 0...1 across and down the free space around it, so it
    /// keeps its corner or edge when the window changes size.
    var statisticsPlacement: CGPoint {
        didSet { defaults.set([statisticsPlacement.x, statisticsPlacement.y], forKey: Keys.statisticsPlacement) }
    }

    /// The interface language chosen in Settings (a code from `languages`); nil follows the
    /// system. Stored the standard way (AppleLanguages in the app's own defaults), so it takes
    /// effect at the next launch.
    var language: String? {
        didSet {
            if let language { defaults.set([language], forKey: Keys.appleLanguages) }
            else { defaults.removeObject(forKey: Keys.appleLanguages) }
        }
    }

    /// The interface languages, each named in itself.
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"),
        ("ko", "한국어"), ("fr", "Français"), ("it", "Italiano"),
    ]

    /// ⌘ behaviour for new connections.
    var defaultCommandKey: CommandKeyMapping {
        didSet { defaults.set(defaultCommandKey.rawValue, forKey: Keys.defaultCommandKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openInTabs = defaults.bool(forKey: Keys.openInTabs)
        defaultRenderScale = defaults.object(forKey: Keys.defaultRenderScale) as? Int ?? DisplayOptions().renderScale
        showsStatistics = defaults.bool(forKey: Keys.showsStatistics)
        compactStatistics = defaults.bool(forKey: Keys.compactStatistics)
        let placement = defaults.array(forKey: Keys.statisticsPlacement) as? [Double] ?? []
        statisticsPlacement = placement.count == 2 ? CGPoint(x: placement[0], y: placement[1]) : CGPoint(x: 1, y: 0)
        defaultCommandKey = defaults.string(forKey: Keys.defaultCommandKey).flatMap(CommandKeyMapping.init) ?? .control
        // Only the app's own setting counts; the global list is the system's choice.
        let own = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:))
        language = (own?[Keys.appleLanguages] as? [String])?.first
    }

    private enum Keys {
        static let openInTabs = "OpenSessionsInTabs"
        static let defaultRenderScale = "DefaultRenderScale"
        static let showsStatistics = "ShowSessionStatistics"
        static let compactStatistics = "CompactSessionStatistics"
        static let statisticsPlacement = "SessionStatisticsPlacement"
        static let defaultCommandKey = "DefaultCommandKey"
        static let appleLanguages = "AppleLanguages"
    }
}
