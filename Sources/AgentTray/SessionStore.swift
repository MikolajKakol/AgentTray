import AgentTrayCore
import AppKit
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
    /// Sessions marked as seen: session id to its `acknowledgementMarker` at that moment.
    /// Kept in the app's own `UserDefaults`, never in the tracked `.claude` directories.
    private(set) var acknowledged: [String: Date] = [:] {
        didSet {
            defaults.set(acknowledged.mapValues(\.timeIntervalSince1970), forKey: Self.acknowledgedKey)
        }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor = SessionMonitor()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var appliedGeneration = 0
    @ObservationIgnored private var timers: [Task<Void, Never>] = []

    @ObservationIgnored private let defaults: UserDefaults
    private static let acknowledgedKey = "acknowledgedSessions"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.acknowledgedKey) as? [String: Double] ?? [:]
        acknowledged = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    var listing: SessionListing {
        SessionListing(sessions: sessions, thresholds: settings.thresholds, now: now, acknowledged: acknowledged)
    }

    /// Marks the session as seen until it records something new.
    func acknowledge(_ row: SessionRow) {
        acknowledged[row.id] = row.snapshot.acknowledgementMarker
    }

    func acknowledgeAll() {
        var updated = acknowledged
        for row in listing.rows where row.canAcknowledge {
            updated[row.id] = row.snapshot.acknowledgementMarker
        }
        acknowledged = updated
    }

    func unacknowledge(_ row: SessionRow) {
        acknowledged[row.id] = nil
    }

    /// Brings the window the session is open in to the front; beeps when there is none.
    func focusTerminal(_ row: SessionRow) {
        let snapshot = row.snapshot
        let monitor = monitor
        Task {
            let entries = await monitor.registryEntries(directoryPath: snapshot.directoryPath)
            let processes = await Task.detached(priority: .userInitiated) { ProcessTable.read() }.value
            if !TerminalFocuser.focus(snapshot, entries: entries, processes: processes) {
                NSSound.beep()
            }
        }
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
        // Forget acknowledgements of sessions that are gone.
        let ids = Set(update.sessions.map(\.id))
        if acknowledged.keys.contains(where: { !ids.contains($0) }) {
            acknowledged = acknowledged.filter { ids.contains($0.key) }
        }
        trackedDirectories = update.directories
        matchCounts = update.matchCounts
        now = Date()
        watcher?.watch(update.watchPaths)
    }
}
