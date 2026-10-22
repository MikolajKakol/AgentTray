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
            logger.notice("No live process for session \(snapshot.sessionId, privacy: .public)")
            return false
        }
        if process.workingDirectory == nil {
            process.workingDirectory = ProcessTable.workingDirectory(of: process.pid)
        }
        let processInfo = "pid \(process.pid), tty \(process.tty ?? "-"), cwd \(process.workingDirectory ?? "-")"
        logger.notice("Session \(snapshot.sessionId, privacy: .public): \(processInfo, privacy: .public)")
        guard let app = owningApplication(of: process, in: processes) else {
            logger.notice("No app above pid \(process.pid)")
            return false
        }
        logger.notice("Terminal app: \(app.bundleIdentifier ?? "?", privacy: .public), pid \(app.processIdentifier)")
        if app.bundleIdentifier == Ghostty.bundleIdentifier {
            let titles = [snapshot.title, snapshot.facts.customTitle, snapshot.facts.aiTitle, snapshot.registryName]
                .compactMap { $0 }
            let surfaces = Ghostty.surfaces()
            let surfaceList = surfaces.map { list in
                list.map { "\($0.id) [\($0.name)] \($0.workingDirectory ?? "-") \($0.tty ?? "-")" }.joined(separator: " | ")
            } ?? "error"
            logger.notice("Ghostty surfaces: \(surfaceList, privacy: .public); titles: \(titles.joined(separator: " | "), privacy: .public)")
            if let surfaces, let surface = TerminalLocator.surface(for: process, titles: titles, in: surfaces) {
                // Ghostty's `focus` orders the window front and only then activates the app, which
                // switches to the window's desktop. Ordered front by an already active Ghostty, the
                // window is moved to the current desktop instead. So Ghostty is not activated here,
                // only allowed to activate itself.
                NSApp.yieldActivation(to: app)
                let focused = Ghostty.focus(surfaceId: surface.id)
                logger.notice("Focus surface \(surface.id, privacy: .public): \(focused)")
                if focused { return true }
            } else {
                logger.notice("No single Ghostty surface for pid \(process.pid); activating the app only")
            }
        }
        let activated = app.activate()
        logger.notice("Activate \(app.bundleIdentifier ?? "?", privacy: .public): \(activated)")
        return activated
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
    /// Separators are set before `tell`: inside it `tab` means Ghostty's tab class, not the character.
    static func surfaces() -> [TerminalSurface]? {
        let source = """
        set fieldSeparator to character id 9
        set lineSeparator to character id 10
        set output to ""
        tell application id "\(bundleIdentifier)"
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
                set output to output & surfaceId & fieldSeparator & ttyName & fieldSeparator & surfaceDirectory & fieldSeparator & surfaceTitle & lineSeparator
            end repeat
        end tell
        return output
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

    /// No `activate` after `focus`: Ghostty activates itself after ordering the window front.
    /// Handled before that, an `activate` makes Ghostty order the window front while active, and
    /// the window moves to the current desktop.
    static func focus(surfaceId: String) -> Bool {
        let quoted = surfaceId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(bundleIdentifier)"
            repeat with t in terminals
                if ((id of t) as text) is "\(quoted)" then
                    focus t
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
