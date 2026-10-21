import Foundation

/// A process on the host, as the app reads it from the kernel.
public struct HostProcess: Sendable, Equatable {
    public var pid: Int32
    public var parentPid: Int32
    public var startTime: Date
    /// Controlling terminal, e.g. `/dev/ttys008`; nil for processes without one.
    public var tty: String?
    /// Empty when the app did not read them (it reads them only for `ssh`).
    public var arguments: [String]
    public var workingDirectory: String?

    public init(
        pid: Int32, parentPid: Int32 = 1, startTime: Date, tty: String? = nil,
        arguments: [String] = [], workingDirectory: String? = nil
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.startTime = startTime
        self.tty = tty
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

/// A terminal surface (tab or split) as Ghostty's AppleScript dictionary reports it.
public struct TerminalSurface: Sendable, Equatable {
    public var id: String
    /// Current title, e.g. `✳ Walidacja formularza` while Claude Code runs in it.
    public var name: String
    public var workingDirectory: String?
    /// Only Ghostty newer than 1.3.1 reports it.
    public var tty: String?

    public init(id: String, name: String, workingDirectory: String? = nil, tty: String? = nil) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.tty = tty
    }
}

/// A Speedwave project's Claude Code home: `<dataDirectory>/claude-home/<name>/.claude`.
public struct SpeedwaveProject: Sendable, Equatable {
    /// E.g. `/Users/x/.speedwave` or `/Users/x/.speedwave-dev`.
    public var dataDirectory: String
    public var name: String

    /// `speedwave_<project>_claude`; the prefix is the data directory's name without the dot.
    public var containerName: String {
        var prefix = (dataDirectory as NSString).lastPathComponent
        if prefix.hasPrefix(".") { prefix.removeFirst() }
        return "\(prefix)_\(name)_claude"
    }

    public init(dataDirectory: String, name: String) {
        self.dataDirectory = dataDirectory
        self.name = name
    }

    public init?(claudeDirectory path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[parts.count - 1] == ".claude", parts[parts.count - 3] == "claude-home" else {
            return nil
        }
        self.init(dataDirectory: "/" + parts[..<(parts.count - 3)].joined(separator: "/"), name: parts[parts.count - 2])
    }
}

/// Finds the terminal a session is open in. See "Przejście do terminala" in SPEC.md.
public enum TerminalLocator {
    /// How much later than its `ssh` a container's `claude` may start (image checks, `nerdctl exec`).
    static let containerStartWindow: ClosedRange<TimeInterval> = -5 ... 120
    /// A local `claude` process and its registry file agree on the start time within this.
    static let localStartTolerance: TimeInterval = 5

    /// The host process whose terminal shows `sessionId` now: the `ssh` running `claude` in a
    /// Speedwave container, or the local `claude` process. Nil when no live process has it open.
    ///
    /// `entries` are all registry files of the session's `.claude` directory, including stale ones.
    public static func process(
        forSession sessionId: String, claudeDirectory: String,
        entries: [SessionRegistryEntry], processes: [HostProcess]
    ) -> HostProcess? {
        let terminalEntries = entries.filter { $0.isTerminalSession && $0.startedAt != nil }
        if let project = SpeedwaveProject(claudeDirectory: claudeDirectory) {
            return containerProcess(forSession: sessionId, project: project, entries: terminalEntries, processes: processes)
        }
        // Several files can name the session (e.g. resumed in another window); the newest live one wins.
        let byRecency = terminalEntries
            .filter { $0.sessionId == sessionId && $0.pid != nil }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        for entry in byRecency {
            if let process = processes.first(where: { $0.pid == entry.pid }),
               let startedAt = entry.startedAt,
               abs(process.startTime.timeIntervalSince(startedAt)) <= localStartTolerance {
                return process
            }
        }
        return nil
    }

    /// Container pids mean nothing on the host. Each live `ssh` is paired with the registry
    /// file whose process started closest after it; the pair's current `sessionId` says which
    /// conversation that window shows.
    private static func containerProcess(
        forSession sessionId: String, project: SpeedwaveProject,
        entries: [SessionRegistryEntry], processes: [HostProcess]
    ) -> HostProcess? {
        var best: (process: HostProcess, distance: TimeInterval)?
        for process in processes where isInteractiveSSH(process, into: project) {
            let paired = entries.compactMap { entry -> (entry: SessionRegistryEntry, delay: TimeInterval)? in
                guard let startedAt = entry.startedAt else { return nil }
                let delay = startedAt.timeIntervalSince(process.startTime)
                return containerStartWindow.contains(delay) ? (entry, delay) : nil
            }
            .min { abs($0.delay) < abs($1.delay) }
            guard let paired, paired.entry.sessionId == sessionId else { continue }
            if best == nil || abs(paired.delay) < best!.distance {
                best = (process, abs(paired.delay))
            }
        }
        return best?.process
    }

    /// `ssh -t … lima-<vm> -- sudo nerdctl exec -it … <prefix>_<project>_claude … claude …`
    /// started by the `speedwave` CLI. Speedwave Desktop's own `ssh` (no terminal,
    /// `claude -p --output-format stream-json`) is skipped.
    static func isInteractiveSSH(_ process: HostProcess, into project: SpeedwaveProject) -> Bool {
        guard process.tty != nil, let executable = process.arguments.first,
              (executable as NSString).lastPathComponent == "ssh" else { return false }
        let tokens = process.arguments.dropFirst().flatMap { argument in
            argument.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        }
        return tokens.contains(project.containerName)
            && process.arguments.contains { $0.hasPrefix(project.dataDirectory + "/") }
            && !tokens.contains("stream-json")
    }

    /// The Ghostty surface showing `process`'s terminal. By tty when Ghostty reports it;
    /// otherwise by the title Claude Code sets and the directory the `speedwave` command
    /// was started in. Nil when that does not single out one surface.
    public static func surface(
        for process: HostProcess, titles: [String], in surfaces: [TerminalSurface]
    ) -> TerminalSurface? {
        if let tty = process.tty, surfaces.contains(where: { $0.tty != nil }) {
            return surfaces.first { $0.tty == tty }
        }
        let wanted = titles.map(normalizedTitle).filter { !$0.isEmpty }
        let titled = surfaces.filter { surface in
            let name = normalizedTitle(surface.name)
            return wanted.contains { titlesMatch(name, $0) }
        }
        let directory = process.workingDirectory.map(normalizedPath)
        let inDirectory = surfaces.filter { surface in
            directory != nil && surface.workingDirectory.map(normalizedPath) == directory
        }
        let both = titled.filter { surface in inDirectory.contains { $0.id == surface.id } }
        if both.count == 1 { return both[0] }
        if both.count > 1 { return nil }
        if titled.count == 1 { return titled[0] }
        if titled.isEmpty, inDirectory.count == 1 { return inDirectory[0] }
        return nil
    }

    /// Drops the activity glyph Claude Code puts before the title (`✳`, spinner frames),
    /// collapses whitespace and ignores case.
    public static func normalizedTitle(_ title: String) -> String {
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber }
        return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Equal, or the terminal title is the beginning of the session title: whole words,
    /// or cut off with an ellipsis. At least 8 characters, so a stray word does not match.
    static func titlesMatch(_ terminal: String, _ session: String) -> Bool {
        if terminal == session { return true }
        for ellipsis in ["…", "..."] where terminal.hasSuffix(ellipsis) {
            let stem = String(terminal.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces)
            if stem.count >= 8, session.hasPrefix(stem) { return true }
        }
        return terminal.count >= 8 && session.hasPrefix(terminal + " ")
    }

    private static func normalizedPath(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
