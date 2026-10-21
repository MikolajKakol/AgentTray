import AgentTrayCore
import Foundation
import Observation

/// Main-actor state for the UI. File work happens in `SessionMonitor`.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [SessionSnapshot] = []
    private(set) var trackedDirectories: [TrackedDirectory] = []
    private(set) var matchCounts: [String: Int] = [:]
    /// Ticks every second so relative times and the uncertain-state threshold stay current.
    private(set) var now = Date()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor = SessionMonitor()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var appliedGeneration = 0
    @ObservationIgnored private var timers: [Task<Void, Never>] = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    var listing: SessionListing {
        SessionListing(sessions: sessions, thresholds: settings.thresholds, now: now)
    }

    func start() {
        guard watcher == nil else { return }
        let monitor = monitor
        watcher = FileWatcher { [weak self] paths in
            Task { @MainActor [weak self] in
                let update = await monitor.handle(paths: paths)
                self?.apply(update)
            }
        }
        reconfigure()

        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.now = Date()
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let update = await monitor.reexpand()
                self?.apply(update)
            }
        })
    }

    /// Call after patterns or thresholds change.
    func reconfigure() {
        let patterns = settings.patterns
        let thresholds = settings.thresholds
        Task {
            let update = await monitor.configure(patterns: patterns, thresholds: thresholds)
            apply(update)
        }
    }

    private func apply(_ update: MonitorUpdate) {
        // Updates can finish out of order; keep only the newest.
        guard update.generation > appliedGeneration else { return }
        appliedGeneration = update.generation
        sessions = update.sessions
        trackedDirectories = update.directories
        matchCounts = update.matchCounts
        now = Date()
        watcher?.watch(update.watchPaths)
    }
}
