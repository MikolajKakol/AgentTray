import Foundation
import Testing
@testable import AgentTrayCore

/// Shapes taken from a real machine: Speedwave CLI windows in Ghostty, `sessions/*.json`
/// before and after `/clear`. Names and paths are neutral.
struct TerminalLocatorTests {
    private let claudeDirectory = "/Users/u/.speedwave-dev/claude-home/tutto/.claude"
    private let project = SpeedwaveProject(dataDirectory: "/Users/u/.speedwave-dev", name: "tutto")

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_792_599_000 + seconds) }

    private func ssh(pid: Int32, started: TimeInterval, tty: String? = "/dev/ttys008",
                     container: String = "speedwave-dev_tutto_claude",
                     dataDirectory: String = "/Users/u/.speedwave-dev", cwd: String? = "/Users/u/work/a") -> HostProcess {
        HostProcess(
            pid: pid, parentPid: pid - 1, startTime: at(started), tty: tty,
            arguments: [
                "ssh", "-F", "\(dataDirectory)/lima/speedwave-dev/ssh.config", "-t", "-o", "LogLevel=ERROR",
                "lima-speedwave-dev", "--",
                "sudo nerdctl exec -it -e 'TERM=xterm-ghostty' \(container) env 'SPW_SESSION_INSTANCE_ID=ffd310ff' /usr/local/bin/claude --ide",
            ],
            workingDirectory: cwd
        )
    }

    private func entry(_ sessionId: String, pid: Int32, started: TimeInterval, updated: TimeInterval? = nil,
                       kind: String = "interactive", entrypoint: String = "cli") -> SessionRegistryEntry {
        SessionRegistryEntry(sessionId: sessionId, name: "workspace-\(pid)", updatedAt: at(updated ?? started + 10),
                             pid: pid, startedAt: at(started), kind: kind, entrypoint: entrypoint)
    }

    @Test func registryDecodesProcessFields() throws {
        let entry = try SessionRegistryEntry.decode(Data(contentsOf: Fixtures.url("sessions-3398.json")))
        #expect(entry.pid == 3398)
        #expect(entry.startedAt == Date(timeIntervalSince1970: 1_792_569_554.606))
        #expect(entry.kind == "interactive")
        #expect(entry.entrypoint == "cli")
        #expect(entry.isTerminalSession)
        #expect(!SessionRegistryEntry(sessionId: "s", kind: "bg").isTerminalSession)
        #expect(!SessionRegistryEntry(sessionId: "s", entrypoint: "sdk-cli").isTerminalSession)
    }

    @Test func speedwaveProjectFromDirectory() {
        #expect(SpeedwaveProject(claudeDirectory: claudeDirectory) == project)
        #expect(project.containerName == "speedwave-dev_tutto_claude")
        #expect(SpeedwaveProject(claudeDirectory: "/Users/u/.speedwave/claude-home/resql/.claude")?.containerName
                == "speedwave_resql_claude")
        #expect(SpeedwaveProject(claudeDirectory: "/Users/u/.claude") == nil)
    }

    @Test func sshIsPairedWithTheProcessStartedRightAfterIt() {
        // ssh started 18:12:36, claude's registry file says 18:12:38. Stale files from closed
        // windows and other live windows started much earlier.
        let entries = [
            entry("current", pid: 296, started: 2),
            entry("stale", pid: 222, started: -86_400),
            entry("other", pid: 711, started: -3_600),
        ]
        let processes = [ssh(pid: 42159, started: 0), ssh(pid: 30000, started: -3_602, tty: "/dev/ttys002")]
        let found = TerminalLocator.process(forSession: "current", claudeDirectory: claudeDirectory,
                                            entries: entries, processes: processes)
        #expect(found?.pid == 42159)
        let other = TerminalLocator.process(forSession: "other", claudeDirectory: claudeDirectory,
                                            entries: entries, processes: processes)
        #expect(other?.pid == 30000)
        #expect(TerminalLocator.process(forSession: "stale", claudeDirectory: claudeDirectory,
                                        entries: entries, processes: processes) == nil)
    }

    @Test func clearMovesTheWindowToTheNewSession() {
        // `/clear` rewrites the same file: new sessionId, same pid and startedAt.
        let before = [entry("old-conversation", pid: 296, started: 2)]
        let after = [entry("new-conversation", pid: 296, started: 2, updated: 300)]
        let processes = [ssh(pid: 42159, started: 0)]
        #expect(TerminalLocator.process(forSession: "old-conversation", claudeDirectory: claudeDirectory,
                                        entries: before, processes: processes)?.pid == 42159)
        #expect(TerminalLocator.process(forSession: "old-conversation", claudeDirectory: claudeDirectory,
                                        entries: after, processes: processes) == nil)
        #expect(TerminalLocator.process(forSession: "new-conversation", claudeDirectory: claudeDirectory,
                                        entries: after, processes: processes)?.pid == 42159)
    }

    @Test func otherProjectsDesktopAndBackgroundJobsAreIgnored() {
        let entries = [
            entry("s", pid: 296, started: 2),
            entry("desktop", pid: 11, started: 501, entrypoint: "sdk-cli"),
            entry("job", pid: 12, started: 1, kind: "bg"),
        ]
        var desktop = ssh(pid: 26078, started: 500, tty: nil)
        desktop.arguments[desktop.arguments.count - 1] += " -p --output-format stream-json"
        let processes = [
            ssh(pid: 1, started: 0, container: "speedwave-dev_resql_claude"),
            ssh(pid: 2, started: 0, container: "speedwave_tutto_claude", dataDirectory: "/Users/u/.speedwave"),
            desktop,
        ]
        for id in ["s", "desktop", "job"] {
            #expect(TerminalLocator.process(forSession: id, claudeDirectory: claudeDirectory,
                                            entries: entries, processes: processes) == nil, "\(id)")
        }
    }

    @Test func localSessionUsesThePidWhenStartTimesAgree() {
        let directory = "/Users/u/.claude"
        let entries = [entry("s", pid: 500, started: 0)]
        let live = HostProcess(pid: 500, startTime: at(0.4), tty: "/dev/ttys003")
        #expect(TerminalLocator.process(forSession: "s", claudeDirectory: directory,
                                        entries: entries, processes: [live])?.tty == "/dev/ttys003")
        // The pid was reused by an unrelated process after the session ended.
        let reused = HostProcess(pid: 500, startTime: at(9_000), tty: "/dev/ttys003")
        #expect(TerminalLocator.process(forSession: "s", claudeDirectory: directory,
                                        entries: entries, processes: [reused]) == nil)
    }

    // MARK: Ghostty surfaces

    private let surfaces = [
        TerminalSurface(id: "1", name: "…/work/speedwave-dev", workingDirectory: "/Users/u/work/speedwave-dev"),
        TerminalSurface(id: "2", name: "✳ Implement login", workingDirectory: "/Users/u/work"),
        TerminalSurface(id: "3", name: "✳ Say hi", workingDirectory: "/Users/u/work/a"),
        TerminalSurface(id: "4", name: "osascript -e …", workingDirectory: "/Users/u/work/a"),
        TerminalSurface(id: "5", name: "~", workingDirectory: "/Users/u"),
    ]

    @Test func surfaceByTitleIgnoringActivityGlyph() {
        let process = HostProcess(pid: 1, startTime: at(0), tty: "/dev/ttys002", workingDirectory: "/Users/u/work")
        #expect(TerminalLocator.surface(for: process, titles: ["implement login"], in: surfaces)?.id == "2")
        // Spinner frame while the agent works.
        var busy = surfaces
        busy[1].name = "✻ Implement login"
        #expect(TerminalLocator.surface(for: process, titles: ["Implement login"], in: busy)?.id == "2")
    }

    @Test func directoryBreaksTitleTiesAndStandsInWhenNoTitleMatches() {
        var twins = surfaces
        twins[4] = TerminalSurface(id: "5", name: "✳ Say hi", workingDirectory: "/Users/u/elsewhere")
        let process = HostProcess(pid: 1, startTime: at(0), tty: "/dev/ttys008", workingDirectory: "/Users/u/work/a")
        #expect(TerminalLocator.surface(for: process, titles: ["Say hi"], in: twins)?.id == "3")

        let onlyWindowThere = HostProcess(pid: 1, startTime: at(0), workingDirectory: "/Users/u/work/speedwave-dev")
        #expect(TerminalLocator.surface(for: onlyWindowThere, titles: ["Something else"], in: surfaces)?.id == "1")
        // Two surfaces in that directory and no title to tell them apart.
        let ambiguous = HostProcess(pid: 1, startTime: at(0), workingDirectory: "/Users/u/work/a")
        #expect(TerminalLocator.surface(for: ambiguous, titles: ["Something else"], in: surfaces) == nil)
    }

    @Test func ttyWinsWhenGhosttyReportsIt() {
        var withTTY = surfaces
        for index in withTTY.indices { withTTY[index].tty = "/dev/ttys00\(index)" }
        let process = HostProcess(pid: 1, startTime: at(0), tty: "/dev/ttys004", workingDirectory: "/Users/u/work")
        #expect(TerminalLocator.surface(for: process, titles: ["Implement login"], in: withTTY)?.id == "5")
    }

    @Test func truncatedTerminalTitleMatches() {
        #expect(TerminalLocator.titlesMatch("bardzo długi tytuł…", "bardzo długi tytuł sesji"))
        #expect(!TerminalLocator.titlesMatch("abc…", "abcdef"))
        #expect(TerminalLocator.normalizedTitle("✳  Say   Hi ") == "say hi")
    }
}
