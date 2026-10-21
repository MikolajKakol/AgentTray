import AgentTrayCore
import Foundation
import Observation

/// User settings, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let patterns = "patterns"
        static let dimAfterHours = "dimAfterHours"
        static let hideAfterHours = "hideAfterHours"
        static let uncertainAfterSeconds = "uncertainAfterSeconds"
    }

    static let defaultPatterns = ["~/.claude"]

    private let defaults: UserDefaults

    var patterns: [String] {
        didSet { defaults.set(patterns, forKey: Key.patterns) }
    }

    var dimAfterHours: Int {
        didSet { defaults.set(dimAfterHours, forKey: Key.dimAfterHours) }
    }

    /// Always greater than `dimAfterHours`; the settings view enforces it.
    var hideAfterHours: Int {
        didSet { defaults.set(hideAfterHours, forKey: Key.hideAfterHours) }
    }

    var uncertainAfterSeconds: Int {
        didSet { defaults.set(uncertainAfterSeconds, forKey: Key.uncertainAfterSeconds) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        patterns = defaults.stringArray(forKey: Key.patterns) ?? Self.defaultPatterns
        let dim = defaults.object(forKey: Key.dimAfterHours) as? Int ?? 10
        let hide = defaults.object(forKey: Key.hideAfterHours) as? Int ?? 40
        dimAfterHours = max(1, dim)
        hideAfterHours = max(max(1, dim) + 1, hide)
        uncertainAfterSeconds = max(1, defaults.object(forKey: Key.uncertainAfterSeconds) as? Int ?? 10)
    }

    var thresholds: Thresholds {
        Thresholds(
            dimAfter: TimeInterval(dimAfterHours) * 3600,
            hideAfter: TimeInterval(hideAfterHours) * 3600,
            uncertainAfter: TimeInterval(uncertainAfterSeconds)
        )
    }
}
