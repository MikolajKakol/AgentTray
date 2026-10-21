import Foundation
import Testing
@testable import AgentTrayCore

struct ClaudeDirectoryScannerTests {
    private let sessionId = "11111111-2222-3333-4444-555555555555"

    private func setUp() throws -> (TemporaryDirectory, ClaudeDirectoryScanner) {
        let temp = try TemporaryDirectory()
        let claude = try temp.makeDirectory(".claude")
        try temp.makeDirectory(".claude/sessions")
        try temp.makeDirectory(".claude/projects/-workspace")
        let scanner = ClaudeDirectoryScanner(directory: TrackedDirectory(url: claude, sourceLabel: "alpha", pattern: "x"))
        return (temp, scanner)
    }

    @Test func buildsSnapshotsFromTranscriptsAndRegistry() throws {
        let (temp, scanner) = try setUp()
        try FileManager.default.copyItem(at: Fixtures.url("02-thinking.jsonl"),
                                         to: temp.url.appendingPathComponent(".claude/projects/-workspace/\(sessionId).jsonl"))
        try FileManager.default.copyItem(at: Fixtures.url("sessions-3398.json"),
                                         to: temp.url.appendingPathComponent(".claude/sessions/3398.json"))
        try temp.write(".claude/sessions/3398.abc.key", "ignored")
        try temp.write(".claude/projects/-workspace/\(sessionId)/subagents/agent-a1.jsonl", "{not read}\n")

        let snapshots = scanner.refresh(thresholds: .default, now: Date())
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.title == "workspace-56", "no ai-title in transcript: falls back to the registry name")
        #expect(snapshot.sourceLabel == "alpha")
        #expect(snapshot.workingDirectoryName == "workspace")
        #expect(snapshot.lastPrompt == "Dodaj walidację formularza logowania")
        #expect(snapshot.sessionId == sessionId)
        // The newest of the last record, the file mtime and the registry's `updatedAt`.
        #expect(snapshot.lastActivity >= fixtureTime(3))
    }

    @Test func titleFallsBackToSessionIdPrefix() throws {
        let (temp, scanner) = try setUp()
        try temp.write(".claude/projects/-workspace/abcdef0123456789.jsonl", Line.prompt("Hej"))
        let snapshot = try #require(scanner.refresh(thresholds: .default, now: Date()).first)
        #expect(snapshot.title == "abcdef01")
    }

    @Test func picksUpChangesAndRemovals() throws {
        let (temp, scanner) = try setUp()
        let path = ".claude/projects/-workspace/s1.jsonl"
        try temp.write(path, Line.prompt("Hej"))
        #expect(scanner.refresh(thresholds: .default, now: Date()).first?.lastMessage == nil)

        try temp.append(path, Line.text("Odpowiedź") + Line.turnDuration())
        let changed = temp.url.appendingPathComponent(".claude/projects/-workspace").path + "/"
        #expect(scanner.refresh(changedPaths: [changed], thresholds: .default, now: Date()).first?.lastMessage == "Odpowiedź")

        try temp.write(".claude/projects/-other/s2.jsonl", Line.prompt("Druga"))
        let projects = temp.url.appendingPathComponent(".claude/projects").path
        #expect(scanner.refresh(changedPaths: [projects], thresholds: .default, now: Date()).count == 2)

        try FileManager.default.removeItem(at: temp.url.appendingPathComponent(path))
        let remaining = scanner.refresh(changedPaths: [changed], thresholds: .default, now: Date())
        #expect(remaining.map(\.sessionId) == ["s2"])

        try FileManager.default.removeItem(at: temp.url.appendingPathComponent(".claude/projects/-other"))
        #expect(scanner.refresh(thresholds: .default, now: Date()).isEmpty)
    }

    @Test func transcriptsOlderThanHideThresholdAreNotRead() throws {
        let (temp, scanner) = try setUp()
        let file = try temp.write(".claude/projects/-workspace/old.jsonl", Line.prompt("Stara sesja"))
        let old = Date().addingTimeInterval(-50 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        #expect(scanner.refresh(thresholds: .default, now: Date()).isEmpty)

        try temp.append(".claude/projects/-workspace/old.jsonl", Line.text("Ożyła"))
        #expect(scanner.refresh(thresholds: .default, now: Date()).first?.lastMessage == "Ożyła")
    }

    @Test func scanningDoesNotWriteToTheDirectory() throws {
        let (temp, scanner) = try setUp()
        try temp.write(".claude/projects/-workspace/s1.jsonl", Line.prompt("Hej"))
        try FileManager.default.copyItem(at: Fixtures.url("sessions-3398.json"),
                                         to: temp.url.appendingPathComponent(".claude/sessions/3398.json"))
        func listing() throws -> [String: Date] {
            var result: [String: Date] = [:]
            let enumerator = FileManager.default.enumerator(atPath: temp.url.path)!
            while let path = enumerator.nextObject() as? String {
                let attributes = try FileManager.default.attributesOfItem(atPath: temp.url.appendingPathComponent(path).path)
                result[path] = attributes[.modificationDate] as? Date
            }
            return result
        }
        let before = try listing()
        scanner.refresh(thresholds: .default, now: Date())
        scanner.refresh(changedPaths: [temp.url.appendingPathComponent(".claude").path], thresholds: .default, now: Date())
        #expect(try listing() == before)
    }
}

struct SessionListingTests {
    private let now = fixtureTime(100 * 3600)

    private func snapshot(_ id: String, _ facts: SessionFacts, idle hours: Double) -> SessionSnapshot {
        SessionSnapshot(
            id: id, sessionId: id, sourceLabel: "lokalny", title: id, workingDirectoryName: nil,
            lastPrompt: nil, lastMessage: nil, lastActivity: now.addingTimeInterval(-hours * 3600), facts: facts
        )
    }

    private func facts(_ lines: [String]) -> SessionFacts {
        try! AgentTrayCoreTests.facts(from: lines)
    }

    @Test func groupsSortsAndCounts() {
        let yourTurn = facts([Line.prompt("a"), Line.text("b"), Line.turnDuration()])
        let question = facts([Line.prompt("a"), Line.toolUse("q", "AskUserQuestion")])
        // An open tool call far older than the threshold, outside bypass mode.
        let uncertain = facts([Line.prompt("a"), Line.toolUse("t", "Bash")])
        let thinking = facts([Line.prompt("a")])

        let listing = SessionListing(sessions: [
            snapshot("turn-new", yourTurn, idle: 0.1),
            snapshot("turn-old", yourTurn, idle: 2),
            snapshot("question", question, idle: 0.01),
            snapshot("uncertain", uncertain, idle: 1),
            snapshot("thinking", thinking, idle: 0.5),
            snapshot("dimmed-question", question, idle: 11),
            snapshot("dimmed-turn", yourTurn, idle: 20),
            snapshot("hidden", yourTurn, idle: 41),
        ], thresholds: .default, now: now)

        #expect(listing.rows.map(\.id) == [
            "question", "turn-old", "turn-new", "uncertain", "thinking", "dimmed-turn", "dimmed-question",
        ])
        #expect(listing.rows.map(\.group) == [.waitingForYou, .waitingForYou, .waitingForYou, .uncertain, .working, .dimmed, .dimmed])
        #expect(listing.waitingCount == 3, "dimmed sessions are not counted")
        #expect(listing.hasUncertain)
    }

    @Test func thresholdsAreConfigurable() {
        let yourTurn = facts([Line.prompt("a"), Line.text("b"), Line.turnDuration()])
        let thresholds = Thresholds(dimAfter: 3600, hideAfter: 2 * 3600, uncertainAfter: 10)
        let listing = SessionListing(sessions: [
            snapshot("fresh", yourTurn, idle: 0.5),
            snapshot("dim", yourTurn, idle: 1.5),
            snapshot("gone", yourTurn, idle: 2.5),
        ], thresholds: thresholds, now: now)
        #expect(listing.rows.map(\.id) == ["fresh", "dim"])
        #expect(listing.rows.map(\.isDimmed) == [false, true])
        #expect(listing.waitingCount == 1)
        #expect(!listing.hasUncertain)
    }

    @Test func ageBoundaries() {
        let last = fixtureTime()
        #expect(SessionAge(lastActivity: last, thresholds: .default, now: last.addingTimeInterval(10 * 3600)) == .fresh)
        #expect(SessionAge(lastActivity: last, thresholds: .default, now: last.addingTimeInterval(10 * 3600 + 1)) == .dimmed)
        #expect(SessionAge(lastActivity: last, thresholds: .default, now: last.addingTimeInterval(40 * 3600)) == .dimmed)
        #expect(SessionAge(lastActivity: last, thresholds: .default, now: last.addingTimeInterval(40 * 3600 + 1)) == .hidden)
    }

    @Test func statusTexts() {
        let last = fixtureTime()
        #expect(StatusText.statusLine(for: .yourTurn, lastActivity: last, now: last.addingTimeInterval(4 * 60 + 5)) == "czeka na Ciebie · 4 min")
        #expect(StatusText.statusLine(for: .runningTool(name: "Bash", summary: "Run tests"), lastActivity: last, now: last.addingTimeInterval(12)) == "wykonuje: Run tests · 12 s")
        #expect(StatusText.statusLine(for: .maybeAwaitingPermission(name: "Bash", summary: "x"), lastActivity: last, now: last.addingTimeInterval(25)) == "może czekać na zgodę: Bash · 25 s")
        #expect(StatusText.label(for: .waitingForSubagents(2)) == "czeka na subagentów (2)")
        #expect(StatusText.label(for: .monitoring(1)) == "monitoruje (1)")
        #expect(StatusText.toolLine(for: .runningTool(name: "Bash", summary: "Run tests")) == "Bash: Run tests")
        #expect(StatusText.toolLine(for: .yourTurn) == nil)
        #expect(StatusText.relative(3 * 3600 + 100) == "3 h")
        #expect(StatusText.relative(50 * 3600) == "2 d")
        #expect(StatusText.relative(-5) == "0 s")
    }
}
