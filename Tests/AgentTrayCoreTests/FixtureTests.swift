import Foundation
import Testing
@testable import AgentTrayCore

/// The expected states table from SPEC.md, section "Testy".
struct FixtureTests {
    private func status(_ name: String, now: Date = fixtureTime(5)) throws -> SessionStatus {
        classify(facts: try Fixtures.facts(name), settings: .default, now: now)
    }

    @Test func turnEnded() throws {
        let facts = try Fixtures.facts("01-turn-ended.jsonl")
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(60)) == .yourTurn)
        #expect(facts.lastPrompt == "Dodaj walidację formularza logowania")
        #expect(facts.lastMessage == "Walidacja dodana, 12 testów przechodzi.")
        #expect(facts.transcriptTitle == "Walidacja formularza logowania")
        #expect(facts.cwd == "/workspace")
    }

    @Test func thinking() throws {
        #expect(try status("02-thinking.jsonl") == .thinking)
    }

    @Test func toolRunningBecomesUncertainAfterThreshold() throws {
        let facts = try Fixtures.facts("03-tool-running.jsonl")
        #expect(facts.permissionMode == "default")
        // The Bash call starts at 10:00:04.
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(4 + 9.9)) == .runningTool(name: "Bash", summary: "Run tests"))
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(4 + 10)) == .maybeAwaitingPermission(name: "Bash", summary: "Run tests"))
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(4 + 600)) == .maybeAwaitingPermission(name: "Bash", summary: "Run tests"))
    }

    @Test func toolRunningInBypassModeNeverUncertain() throws {
        let facts = try Fixtures.facts("04-tool-running-bypass.jsonl")
        #expect(facts.permissionMode == "bypassPermissions")
        for seconds in [5.0, 14, 3600] {
            #expect(classify(facts: facts, settings: .default, now: fixtureTime(seconds)) == .runningTool(name: "Bash", summary: "Run tests"))
        }
    }

    @Test func askUserQuestion() throws {
        #expect(try status("05-ask-user-question.jsonl", now: fixtureTime(3600)) == .askingQuestion)
    }

    @Test func foregroundSubagent() throws {
        #expect(try status("06-subagent-foreground.jsonl", now: fixtureTime(3600)) == .waitingForSubagents(1))
    }

    @Test func backgroundSubagents() throws {
        let facts = try Fixtures.facts("07-subagents-background.jsonl")
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(60)) == .waitingForSubagents(2))
        #expect(facts.lastMessage == "Uruchomiłem dwóch agentów w tle, czekam na wyniki.")
        #expect(facts.backgroundTasks == ["a0000000000000001": .agent, "a0000000000000002": .agent])
    }

    @Test func subagentNotified() throws {
        let facts = try Fixtures.facts("08-subagent-notified.jsonl")
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(400)) == .waitingForSubagents(1))
        #expect(facts.backgroundTasks == ["a0000000000000002": .agent])
    }

    @Test func backgroundBash() throws {
        let facts = try Fixtures.facts("09-background-bash.jsonl")
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(60)) == .monitoring(1))
        #expect(facts.backgroundTasks == ["b0000001": .task])
    }

    // Sessions started from a desktop app (entrypoints `sdk-cli`, `remote_desktop`) never
    // write `system/turn_duration`; the turn ends with an `end_turn` assistant record.
    // Fixtures 10 and 11 come from a real `remote_desktop` session on Claude Code 2.1.306.
    @Test func desktopSessionWithoutTurnDurationEndsOnEndTurn() throws {
        let facts = try Fixtures.facts("10-desktop-turn-ended.jsonl")
        #expect(classify(facts: facts, settings: .default, now: fixtureTime(2 * 3600 + 60)) == .yourTurn)
        #expect(facts.lastMessage == "Scalone do main.")
    }

    @Test func desktopStopHookContinuationAndBackgroundTask() throws {
        let lines = try String(contentsOf: Fixtures.url("11-desktop-stop-hook-continuation.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { String($0) + "\n" }
        let firstEndTurn = try #require(lines.firstIndex { $0.contains("\"end_turn\"") })

        // The first answer ends the turn…
        let ended = try facts(from: Array(lines[...firstEndTurn]))
        #expect(ended.turnEnded)
        // …then the Stop hook feeds back an isMeta user record and the agent carries on.
        let stopHook = try #require(lines.indices.first { $0 > firstEndTurn && lines[$0].contains("\"isMeta\": true") })
        #expect(try facts(from: Array(lines[...stopHook])).turnEnded, "isMeta feedback alone does not reopen the turn")
        let resumed = try #require(lines.indices.first { $0 > stopHook && lines[$0].contains("\"type\": \"assistant\"") })
        #expect(try !facts(from: Array(lines[...resumed])).turnEnded)

        // The whole turn ends with a background Bash still running.
        let all = try Fixtures.facts("11-desktop-stop-hook-continuation.jsonl")
        #expect(classify(facts: all, settings: .default, now: fixtureTime(2 * 3600 + 600)) == .monitoring(1))
        #expect(all.lastPrompt == "Scal zmiany do main")
        #expect(all.lastMessage == "Scalone do main.")
    }

    // Fixture 12 follows a real `Monitor` run on Claude Code 2.1.306: every output line is a
    // `<task-notification>` with `<event>` and no `<status>`; only the last one has `<status>`.
    @Test func monitorStaysMonitoringThroughItsEvents() throws {
        let lines = try String(contentsOf: Fixtures.url("12-monitor.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { String($0) + "\n" }
        let endTurns = lines.indices.filter { lines[$0].contains("\"end_turn\"") }
        #expect(endTurns.count == 3)

        let started = try facts(from: Array(lines[...endTurns[0]]))
        #expect(started.backgroundTasks == ["b0000002": .task])
        #expect(classify(facts: started, settings: .default, now: fixtureTime(30)) == .monitoring(1))

        let afterEvent = try facts(from: Array(lines[...endTurns[1]]))
        #expect(classify(facts: afterEvent, settings: .default, now: fixtureTime(120)) == .monitoring(1))
        // The monitor dies 30 minutes after it started even if the expiry notice is lost.
        #expect(classify(facts: afterEvent, settings: .default, now: fixtureTime(4.2 + 1800)) == .yourTurn)

        let ended = try Fixtures.facts("12-monitor.jsonl")
        #expect(ended.backgroundTasks.isEmpty)
        #expect(classify(facts: ended, settings: .default, now: fixtureTime(400)) == .yourTurn)
        #expect(ended.lastMessage == "Testy e2e przeszły.")
    }

    @Test func sessionRegistry() throws {
        let entry = try SessionRegistryEntry.decode(Data(contentsOf: Fixtures.url("sessions-3398.json")))
        #expect(entry.sessionId == "11111111-2222-3333-4444-555555555555")
        #expect(entry.name == "workspace-56")
        #expect(entry.status == "busy")
        #expect(entry.updatedAt == Date(timeIntervalSince1970: 1_792_569_554.592))
        #expect(entry.statusUpdatedAt == Date(timeIntervalSince1970: 1_792_569_554.592))
    }

    @Test func noFixtureLineIsInvalid() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Fixtures.directory.path).filter { $0.hasSuffix(".jsonl") }
        #expect(names.count == 12)
        for name in names {
            let reader = TranscriptReader(url: Fixtures.url(name))
            try reader.update()
            #expect(reader.invalidLineCount == 0, "\(name)")
        }
    }
}
