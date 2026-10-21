import AgentTrayCore
import AppKit
import os

/// Brings the terminal window a session is open in to the front.
/// See "Przejście do terminala" in SPEC.md.
@MainActor
enum TerminalFocuser {
    private static let logger = Logger(subsystem: "local.agenttray", category: "terminal")

    /// False when no live process has the session open or its app could not be found.
    static func focus(_ snapshot: SessionSnapshot, entries: [SessionRegistryEntry], processes: [HostProcess]) -> Bool {
        guard var process = TerminalLocator.process(
            forSession: snapshot.sessionId, claudeDirectory: snapshot.directoryPath,
            entries: entries, processes: processes
        ) else {
            logger.info("No live process for session \(snapshot.sessionId, privacy: .public)")
            return false
        }
        if process.workingDirectory == nil {
            process.workingDirectory = ProcessTable.workingDirectory(of: process.pid)
        }
        guard let app = owningApplication(of: process, in: processes) else {
            logger.info("No app above pid \(process.pid)")
            return false
        }
        if app.bundleIdentifier == Ghostty.bundleIdentifier {
            let titles = [snapshot.title, snapshot.facts.customTitle, snapshot.facts.aiTitle, snapshot.registryName]
                .compactMap { $0 }
            if let surfaces = Ghostty.surfaces(),
               let surface = TerminalLocator.surface(for: process, titles: titles, in: surfaces),
               Ghostty.focus(surfaceId: surface.id) {
                return true
            }
            logger.info("No single Ghostty surface for pid \(process.pid); activating the app only")
        }
        return app.activate()
    }

    /// The first ancestor that is a regular app (the terminal emulator).
    private static func owningApplication(of process: HostProcess, in processes: [HostProcess]) -> NSRunningApplication? {
        let parents = Dictionary(processes.map { ($0.pid, $0.parentPid) }, uniquingKeysWith: { first, _ in first })
        var pid = process.pid
        var visited: Set<Int32> = []
        while pid > 1, visited.insert(pid).inserted {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parents[pid] else { return nil }
            pid = parent
        }
        return nil
    }
}

/// Ghostty's AppleScript dictionary (1.3+). Needs the Automation permission, asked on first use.
@MainActor
enum Ghostty {
    static let bundleIdentifier = "com.mitchellh.ghostty"
    private static let logger = Logger(subsystem: "local.agenttray", category: "ghostty")

    /// `tty` exists only after 1.3.1; the `try` leaves it empty on older versions.
    static func surfaces() -> [TerminalSurface]? {
        let source = """
        tell application id "\(bundleIdentifier)"
            set output to ""
            repeat with t in terminals
                set surfaceId to ""
                set ttyName to ""
                set surfaceDirectory to ""
                set surfaceTitle to ""
                try
                    set surfaceId to (id of t) as text
                end try
                try
                    set ttyName to (tty of t) as text
                end try
                try
                    set surfaceDirectory to (working directory of t) as text
                end try
                try
                    set surfaceTitle to (name of t) as text
                end try
                set output to output & surfaceId & tab & ttyName & tab & surfaceDirectory & tab & surfaceTitle & linefeed
            end repeat
            return output
        end tell
        """
        guard let output = run(source) else { return nil }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            return TerminalSurface(
                id: fields[0], name: fields[3],
                workingDirectory: fields[2].isEmpty ? nil : fields[2],
                tty: fields[1].isEmpty ? nil : fields[1]
            )
        }
    }

    static func focus(surfaceId: String) -> Bool {
        let quoted = surfaceId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(bundleIdentifier)"
            repeat with t in terminals
                if ((id of t) as text) is "\(quoted)" then
                    focus t
                    activate
                    return "ok"
                end if
            end repeat
        end tell
        return "missing"
        """
        return run(source) == "ok"
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript failed: \(error, privacy: .public)")
            return nil
        }
        return result?.stringValue
    }
}
