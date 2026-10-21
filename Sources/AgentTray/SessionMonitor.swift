import AgentTrayCore
import Foundation

/// Everything the UI needs after a refresh.
struct MonitorUpdate: Sendable {
    var generation: Int
    var sessions: [SessionSnapshot]
    var directories: [TrackedDirectory]
    /// Number of matched `.claude` directories per pattern.
    var matchCounts: [String: Int]
    var watchPaths: [String]
}

/// Owns the directory scanners and does all file reading off the main thread.
actor SessionMonitor {
    private var patterns: [String] = []
    private var thresholds = Thresholds.default
    private var scanners: [String: ClaudeDirectoryScanner] = [:]
    private var directories: [TrackedDirectory] = []
    private var matchCounts: [String: Int] = [:]
    private var patternRoots: [String] = []
    private var generation = 0
    private var lastExpansion = Date.distantPast

    func configure(patterns: [String], thresholds: Thresholds) -> MonitorUpdate {
        self.patterns = patterns
        self.thresholds = thresholds
        expandPatterns()
        for scanner in scanners.values { scanner.refresh(thresholds: thresholds, now: Date()) }
        return makeUpdate()
    }

    /// Periodic re-expansion so new directories show up even without file events.
    /// Also a safety net for missed events: unchanged files cost only a `stat`.
    func reexpand() -> MonitorUpdate {
        expandPatterns()
        for scanner in scanners.values { scanner.refresh(thresholds: thresholds, now: Date()) }
        return makeUpdate()
    }

    /// Handles FSEvents paths; nil means events were dropped and everything is rescanned.
    func handle(paths: [String]?) -> MonitorUpdate {
        let now = Date()
        guard let paths else {
            expandPatterns()
            for scanner in scanners.values { scanner.refresh(thresholds: thresholds, now: now) }
            return makeUpdate()
        }

        var changed: [String: [String]] = [:]
        var outsideTracked = false
        for raw in paths {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
            if let directory = scanners.keys.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                changed[directory, default: []].append(path)
            } else {
                outsideTracked = true
            }
        }
        // Something changed under a pattern root: a new project may have appeared.
        // Throttled because a root like ~/Speedwave also sees unrelated container activity.
        if outsideTracked && now.timeIntervalSince(lastExpansion) >= 1 {
            expandPatterns()
        }
        for (directory, changedPaths) in changed {
            scanners[directory]?.refresh(changedPaths: changedPaths, thresholds: thresholds, now: now)
        }
        return makeUpdate()
    }

    /// All registry files of one tracked directory, stale ones included, for finding a session's terminal.
    func registryEntries(directoryPath: String) -> [SessionRegistryEntry] {
        scanners[directoryPath]?.registryEntries ?? []
    }

    private func expandPatterns() {
        lastExpansion = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [TrackedDirectory] = []
        var seen: Set<String> = []
        var counts: [String: Int] = [:]
        var roots: [String] = []
        for pattern in patterns where !pattern.trimmingCharacters(in: .whitespaces).isEmpty {
            let parsed = PathPattern(pattern, homeDirectory: home)
            let matches = parsed.expand()
            counts[pattern] = matches.count
            roots.append(Self.existingAncestor(of: parsed.literalRoot).path)
            for directory in matches where seen.insert(directory.url.path).inserted {
                found.append(directory)
            }
        }

        var next: [String: ClaudeDirectoryScanner] = [:]
        for directory in found {
            if let existing = scanners[directory.url.path], existing.directory == directory {
                next[directory.url.path] = existing
            } else {
                let scanner = ClaudeDirectoryScanner(directory: directory)
                scanner.refresh(thresholds: thresholds, now: Date())
                next[directory.url.path] = scanner
            }
        }
        scanners = next
        directories = found
        matchCounts = counts
        patternRoots = roots
    }

    private func makeUpdate() -> MonitorUpdate {
        generation += 1
        // A root inside a tracked directory (e.g. `~/.claude` itself) adds only noise.
        var watch = patternRoots.filter { root in
            !directories.contains { root == $0.url.path || root.hasPrefix($0.url.path + "/") }
        }
        for directory in directories {
            let sessions = directory.url.appendingPathComponent("sessions")
            let projects = directory.url.appendingPathComponent("projects")
            let existing = [sessions, projects].filter { FileManager.default.fileExists(atPath: $0.path) }
            watch += existing.isEmpty ? [directory.url.path] : existing.map(\.path)
        }
        return MonitorUpdate(
            generation: generation,
            sessions: scanners.values.flatMap { $0.snapshots() },
            directories: directories,
            matchCounts: matchCounts,
            watchPaths: watch
        )
    }

    /// FSEvents needs an existing path; watch the nearest existing ancestor instead.
    private static func existingAncestor(of url: URL) -> URL {
        var current = url
        while current.path != "/" && !FileManager.default.fileExists(atPath: current.path) {
            current.deleteLastPathComponent()
        }
        return current
    }
}
