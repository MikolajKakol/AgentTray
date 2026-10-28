import AgentTrayCore
import Foundation
import Observation
import os

/// Main-actor state for the UI. File work happens in `SessionMonitor`.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [SessionSnapshot] = []
    private(set) var trackedDirectories: [TrackedDirectory] = []
    private(set) var matchCounts: [String: Int] = [:]
    /// Sessions open in a live terminal process; only these get the "show terminal" button.
    /// Closing a window changes no file, so this is also refreshed on a timer.
    private(set) var sessionsWithTerminal: Set<String> = []
    /// Ticks every second so relative times and the uncertain-state threshold stay current.
    private(set) var now = Date()
    /// Sessions marked as seen: session id to its `acknowledgementMarker` at that moment.
    /// Kept in the app's own `UserDefaults`, never in the tracked `.claude` directories.
    /// Changed only through `setAcknowledged`, which also saves it.
    private(set) var acknowledged: [String: Date] = [:]

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor = SessionMonitor()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var appliedGeneration = 0
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    /// Set after the first scan has been compared with the stored acknowledgements.
    @ObservationIgnored private var reportedStoredMarkers = false

    @ObservationIgnored private let defaults: UserDefaults
    private static let acknowledgedKey = "acknowledgedSessionsV2"
    /// Earlier versions stored seconds since 1970 under this key.
    private static let legacyAcknowledgedKey = "acknowledgedSessions"
    private static let log = Logger(subsystem: "local.agenttray", category: "acknowledgements")

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Self.acknowledgedKey) as? [String: Double] {
            acknowledged = AcknowledgementStorage.decode(stored)
            Self.log.notice("Loaded \(stored.count) acknowledgements")
        } else if let legacy = defaults.dictionary(forKey: Self.legacyAcknowledgedKey) as? [String: Double] {
            setAcknowledged(legacy.mapValues { Date(timeIntervalSince1970: $0) }, reason: "migrated")
            defaults.removeObject(forKey: Self.legacyAcknowledgedKey)
        } else {
            Self.log.notice("No stored acknowledgements")
        }
    }

    var listing: SessionListing {
        SessionListing(sessions: sessions, thresholds: settings.thresholds, now: now, acknowledged: acknowledged)
    }

    /// Marks the session as seen until it records something new.
    func acknowledge(_ row: SessionRow) {
        var updated = acknowledged
        updated[row.id] = row.snapshot.acknowledgementMarker
        setAcknowledged(updated, reason: "acknowledged \(row.id)")
    }

    func acknowledgeAll() {
        var updated = acknowledged
        for row in listing.rows where row.canAcknowledge {
            updated[row.id] = row.snapshot.acknowledgementMarker
        }
        setAcknowledged(updated, reason: "acknowledged all")
    }

    func unacknowledge(_ row: SessionRow) {
        var updated = acknowledged
        updated[row.id] = nil
        setAcknowledged(updated, reason: "restored \(row.id)")
    }

    private func setAcknowledged(_ updated: [String: Date], reason: String) {
        acknowledged = updated
        defaults.set(AcknowledgementStorage.encode(updated), forKey: Self.acknowledgedKey)
        Self.log.notice("Saved \(updated.count) acknowledgements (\(reason, privacy: .public))")
    }

    /// Brings the window the session is open in to the front and, when the session waits for
    /// the user, marks it as seen. When the process is gone by now, the button disappears instead.
    func focusTerminal(_ row: SessionRow) {
        let snapshot = row.snapshot
        let monitor = monitor
        Task {
            let entries = await monitor.registryEntries(directoryPath: snapshot.directoryPath)
            let processes = await Task.detached(priority: .userInitiated) { ProcessTable.read() }.value
            if TerminalFocuser.focus(snapshot, entries: entries, processes: processes) {
                if row.canAcknowledge { acknowledge(row) }
            } else {
                sessionsWithTerminal = await monitor.sessionsWithTerminal(processes: processes)
            }
        }
    }

    private func refreshTerminals() async {
        let processes = await Task.detached(priority: .utility) { ProcessTable.read() }.value
        sessionsWithTerminal = await monitor.sessionsWithTerminal(processes: processes)
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
                try? await Task.sleep(for: .seconds(5))
                await self?.refreshTerminals()
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
        // Forget acknowledgements of sessions that are gone for good.
        let retained = retainedAcknowledgements(
            acknowledged, sessions: update.sessions, thresholds: settings.thresholds, now: Date()
        )
        if retained.count != acknowledged.count {
            setAcknowledged(retained, reason: "dropped \(acknowledged.count - retained.count) of missing sessions")
        }
        if !reportedStoredMarkers && !update.sessions.isEmpty {
            reportedStoredMarkers = true
            reportStoredMarkers(update.sessions)
        }
        trackedDirectories = update.directories
        matchCounts = update.matchCounts
        now = Date()
        watcher?.watch(update.watchPaths)
        // `/clear` and `/resume` rewrite `sessions/*.json`: the button moves with the conversation.
        Task { await refreshTerminals() }
    }

    /// Logs acknowledged sessions whose marker moved since it was stored, for diagnosing
    /// sessions that come back as waiting after a restart.
    private func reportStoredMarkers(_ sessions: [SessionSnapshot]) {
        let present = sessions.filter { acknowledged[$0.id] != nil }
        Self.log.notice("First scan: \(sessions.count) sessions, \(present.count) of them acknowledged")
        for snapshot in present {
            guard let stored = acknowledged[snapshot.id] else { continue }
            let difference = snapshot.acknowledgementMarker.timeIntervalSince(stored)
            if difference > 0 {
                Self.log.notice("Marker moved by \(difference) s since acknowledged: \(snapshot.id, privacy: .public)")
            }
        }
    }
}
