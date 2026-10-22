import Foundation
import Testing
@testable import AgentTrayCore

struct ReducerTests {
    private func status(_ lines: [String], now: Date = fixtureTime(60)) throws -> SessionStatus {
        classify(facts: try facts(from: lines), settings: .default, now: now)
    }

    @Test func unknownTypesAndFieldsAreIgnored() throws {
        let lines = [
            Line.json(["type": "something-new", "payload": ["a": 1]]),
            Line.json(["no-type": true]),
            Line.json(["type": "user", "timestamp": Line.ts(0), "message": ["role": "user", "content": "Hej", "extra": [1, 2]],
                       "origin": ["kind": "human", "future": "x"], "brandNewField": ["nested": true]]),
            Line.json(["type": "assistant", "timestamp": Line.ts(1),
                       "message": ["role": "assistant", "content": [["type": "redacted_thinking", "data": "x"]]]]),
            Line.json(["type": "system", "subtype": "something-else", "timestamp": Line.ts(2)]),
        ]
        let result = try facts(from: lines)
        #expect(result.lastPrompt == "Hej")
        #expect(classify(facts: result, settings: .default, now: fixtureTime(5)) == .thinking)
    }

    @Test func nonObjectLineThrows() {
        #expect(throws: TranscriptParseError.self) { try TranscriptRecord.parse(line: Data("[1,2]".utf8)) }
        #expect(throws: TranscriptParseError.self) { try TranscriptRecord.parse(line: Data("{broken".utf8)) }
    }

    @Test func sidechainRecordsAreSkipped() throws {
        let sidechain = Line.json(["type": "assistant", "isSidechain": true, "timestamp": Line.ts(1),
                                   "message": ["content": [["type": "tool_use", "id": "t1", "name": "AskUserQuestion", "input": [:]]]]])
        #expect(try status([Line.prompt("Hej"), Line.text("Gotowe"), Line.turnDuration(), sidechain]) == .yourTurn)
    }

    @Test func metaUserRecordsDoNotChangePromptOrTurn() throws {
        let meta = Line.json(["type": "user", "isMeta": true, "timestamp": Line.ts(5),
                              "message": ["role": "user", "content": "<local-command-caveat>…"], "origin": ["kind": "human"]])
        let result = try facts(from: [Line.prompt("Prawdziwy prompt"), Line.text("Gotowe"), Line.turnDuration(), meta])
        #expect(result.lastPrompt == "Prawdziwy prompt")
        #expect(result.turnEnded)
    }

    @Test func compactSummaryDoesNotChangePromptOrTurn() throws {
        let summary = Line.json(["type": "user", "isCompactSummary": true, "timestamp": Line.ts(5),
                                 "message": ["role": "user", "content": "This session is being continued…"], "origin": ["kind": "human"]])
        let result = try facts(from: [Line.prompt("Prawdziwy prompt"), Line.text("Gotowe"), Line.turnDuration(), summary])
        #expect(result.lastHumanPrompt == "Prawdziwy prompt")
        #expect(result.turnEnded)
        #expect(result.lastSignificantTimestamp == fixtureTime(3))
    }

    @Test func lastPromptRecordWinsOverHumanRecord() throws {
        let result = try facts(from: [Line.prompt("z rekordu user"), Line.lastPrompt("z last-prompt")])
        #expect(result.lastPrompt == "z last-prompt")
    }

    @Test func customTitleWinsOverAiTitle() throws {
        let custom = Line.json(["type": "custom-title", "customTitle": "Moja nazwa"])
        let result = try facts(from: [custom, Line.aiTitle("Nazwa modelu")])
        #expect(result.transcriptTitle == "Moja nazwa")
    }

    @Test func interruptEndsTurn() throws {
        let interrupt = Line.json(["type": "user", "timestamp": Line.ts(4),
                                   "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]])
        #expect(try status([Line.prompt("Hej"), Line.text("Zaczynam…"), interrupt]) == .yourTurn)
    }

    @Test func toolResultClosesToolUse() throws {
        let lines = [Line.prompt("Hej"), Line.toolUse("t1", "Read", input: ["file_path": "/a/b/notes.md"]), Line.toolResult("t1")]
        #expect(try status(lines) == .thinking)
        #expect(try status(Array(lines.dropLast()), now: fixtureTime(2)) == .runningTool(name: "Read", summary: "notes.md"))
    }

    @Test func endTurnEndsTheTurnOnlyWithoutOpenTools() throws {
        let endTurn = Line.json(["type": "assistant", "timestamp": Line.ts(4),
                                 "message": ["role": "assistant", "content": [["type": "text", "text": "Koniec"]], "stop_reason": "end_turn"]])
        let stopSequence = Line.json(["type": "assistant", "timestamp": Line.ts(4),
                                      "message": ["role": "assistant", "content": [["type": "text", "text": "Koniec"]], "stop_reason": "stop_sequence"]])
        #expect(try status([Line.prompt("Hej"), endTurn]) == .yourTurn)
        #expect(try status([Line.prompt("Hej"), stopSequence]) == .yourTurn)
        // A tool call without a result keeps the turn open.
        let open = [Line.prompt("Hej"), Line.toolUse("q", "AskUserQuestion", at: 1), endTurn]
        #expect(try !facts(from: open).turnEnded)
        #expect(try status(open) == .askingQuestion)
        // `tool_use` and a missing stop_reason do not end the turn.
        #expect(try status([Line.prompt("Hej"), Line.text("Myślę…")]) == .yourTurn, "Line.text uses end_turn")
        let noReason = Line.json(["type": "assistant", "timestamp": Line.ts(4),
                                  "message": ["role": "assistant", "content": [["type": "text", "text": "…"]]]])
        #expect(try status([Line.prompt("Hej"), noReason]) == .thinking)
    }

    @Test func promptTextRendersSlashCommands() {
        let command = "<command-message>grill-with-docs is running…</command-message>\n<command-name>/grill-with-docs</command-name>\n<command-args>docs/SPEC.md</command-args>"
        #expect(TranscriptRecord.promptText(command) == "/grill-with-docs docs/SPEC.md")
        #expect(TranscriptRecord.promptText("<command-name>/clear</command-name>\n<command-args></command-args>") == "/clear")
        #expect(TranscriptRecord.promptText("zwykły prompt") == "zwykły prompt")
    }

    @Test func firstPromptIsKept() throws {
        let result = try facts(from: [Line.prompt("Pierwszy"), Line.text("a"), Line.turnDuration(), Line.prompt("Drugi", at: 10)])
        #expect(result.firstHumanPrompt == "Pierwszy")
        #expect(result.lastPrompt == "Drugi")
    }

    @Test func toolSummaries() {
        #expect(TranscriptRecord.toolSummary(name: "Bash", input: ["command": "ls", "description": "List"]) == "List")
        let long = String(repeating: "x", count: 100)
        #expect(TranscriptRecord.toolSummary(name: "Bash", input: ["command": long]) == String(repeating: "x", count: 60))
        #expect(TranscriptRecord.toolSummary(name: "Edit", input: ["file_path": "/src/App.swift"]) == "App.swift")
        #expect(TranscriptRecord.toolSummary(name: "Write", input: ["file_path": "/src/New.swift"]) == "New.swift")
        #expect(TranscriptRecord.toolSummary(name: "Grep", input: ["pattern": "x"]) == "Grep")
    }

    @Test func questionWinsOverParallelTools() throws {
        let lines = [
            Line.prompt("Hej"),
            Line.toolUse("t1", "Bash", input: ["command": "make"], at: 1),
            Line.toolUse("t2", "Agent", at: 2),
            Line.toolUse("t3", "ExitPlanMode", at: 3),
        ]
        #expect(try status(lines) == .askingQuestion)
        #expect(try status(Array(lines.prefix(3))) == .waitingForSubagents(1))
    }

    @Test func oldestOpenToolProvidesSummary() throws {
        let lines = [
            Line.prompt("Hej"),
            Line.toolUse("t2", "Read", input: ["file_path": "/b.txt"], at: 2),
            Line.toolUse("t1", "Bash", input: ["description": "Build"], at: 1),
        ]
        #expect(try status(lines, now: fixtureTime(3)) == .runningTool(name: "Bash", summary: "Build"))
    }

    @Test func duplicatedNotificationDecrementsPendingAgentsOnce() throws {
        let note = Line.notification(taskId: "a1", summary: "Agent \"x\" completed")
        let lines = [
            Line.prompt("Hej"),
            Line.toolUse("g1", "Agent", at: 1),
            Line.toolResult("g1", toolUseResult: ["isAsync": true, "status": "async_launched", "agentId": "a1"]),
            Line.toolUse("g2", "Agent", at: 2),
            Line.toolResult("g2", toolUseResult: ["isAsync": true, "status": "async_launched", "agentId": "a2"]),
            Line.text("Czekam"),
            Line.turnDuration(pending: 2),
            Line.enqueue(note),
        ]
        let queued = try facts(from: lines)
        #expect(queued.pendingBackgroundAgents == 1)
        #expect(classify(facts: queued, settings: .default, now: fixtureTime(60)) == .waitingForSubagents(1))

        let delivered = try facts(from: lines + [Line.taskNotificationPrompt(note)])
        #expect(delivered.pendingBackgroundAgents == 1)
        #expect(!delivered.turnEnded)
    }

    @Test func lastBackgroundAgentFinishingGivesYourTurn() throws {
        let lines = [
            Line.prompt("Hej"),
            Line.toolUse("g1", "Agent", at: 1),
            Line.toolResult("g1", toolUseResult: ["isAsync": true, "status": "async_launched", "agentId": "a1"]),
            Line.turnDuration(pending: 1),
            Line.enqueue(Line.notification(taskId: "a1")),
        ]
        #expect(try status(lines) == .yourTurn)
    }

    @Test func backgroundBashNotificationEndsMonitoring() throws {
        let lines = [
            Line.prompt("Hej"),
            Line.toolUse("b1", "Bash", input: ["command": "sleep 100", "run_in_background": true]),
            Line.toolResult("b1", toolUseResult: ["backgroundTaskId": "bash1"]),
            Line.turnDuration(),
        ]
        #expect(try status(lines) == .monitoring(1))
        let notified = lines + [Line.enqueue(Line.notification(taskId: "bash1"))]
        #expect(try status(notified) == .yourTurn)
        let delivered = notified + [Line.taskNotificationPrompt(Line.notification(taskId: "bash1")), Line.text("Skończone", at: 12), Line.turnDuration(at: 13)]
        #expect(try status(delivered) == .yourTurn)
    }

    private func monitorLines(id: String = "m1", timeoutMs: Int = 600_000, persistent: Bool = false) -> [String] {
        [
            Line.prompt("Hej"),
            Line.toolUse("t1", "Monitor", input: ["command": "tail -f log", "description": "log"]),
            Line.toolResult("t1", toolUseResult: ["taskId": id, "timeoutMs": timeoutMs, "persistent": persistent]),
            Line.text("Monitoruję", at: 3),
        ]
    }

    @Test func monitorEventDoesNotEndMonitoring() throws {
        let event = Line.monitorEvent(taskId: "m1", event: "ERROR in log")
        let lines = monitorLines() + [Line.enqueue(event), Line.taskNotificationPrompt(event), Line.text("Widzę błąd, czekam dalej", at: 12)]
        #expect(try status(lines) == .monitoring(1))
        #expect(try facts(from: lines).finishedTaskIds.isEmpty)
    }

    @Test func monitorExpiryEndsMonitoring() throws {
        let expired = Line.monitorEvent(taskId: "m1", event: "[Monitor expired after 10m with no events delivered. Re-arm it if you still need the watch.]")
        #expect(try status(monitorLines() + [Line.enqueue(expired)]) == .yourTurn)
    }

    @Test func monitorPastItsTimeoutIsNotCounted() throws {
        // The result record is at 2 s; the monitor gets killed at 2 + 600 s.
        #expect(try status(monitorLines(), now: fixtureTime(601)) == .monitoring(1))
        #expect(try status(monitorLines(), now: fixtureTime(602)) == .yourTurn)
        #expect(try status(monitorLines(persistent: true), now: fixtureTime(3600)) == .monitoring(1))
    }

    @Test func taskStopEndsBackgroundTask() throws {
        let stop = [
            Line.prompt("Zatrzymaj", at: 10),
            Line.toolUse("t2", "TaskStop", input: ["task_id": "m1"], at: 11),
            Line.toolResult("t2", at: 12, toolUseResult: ["message": "Successfully stopped task: m1 (tail -f log)", "task_id": "m1",
                                                          "task_type": "local_bash", "command": "tail -f log"]),
            Line.text("Zatrzymane", at: 13),
        ]
        #expect(try status(monitorLines() + stop) == .yourTurn)

        let bash = [
            Line.prompt("Hej"),
            Line.toolUse("b1", "Bash", input: ["command": "npm run dev", "run_in_background": true]),
            Line.toolResult("b1", toolUseResult: ["backgroundTaskId": "m1"]),
            Line.text("Serwer działa", at: 3),
        ]
        #expect(try status(bash) == .monitoring(1))
        #expect(try status(bash + stop) == .yourTurn)
    }

    @Test func parsesTaskNotifications() {
        let text = "przed " + Line.notification(taskId: "a1", summary: "Agent \"x\" completed") + " po " + Line.notification(taskId: "b2")
        let parsed = TaskNotification.parseAll(in: text)
        #expect(parsed == [
            TaskNotification(taskId: "a1", toolUseId: "toolu_x", status: "completed", summary: "Agent \"x\" completed"),
            TaskNotification(taskId: "b2", toolUseId: "toolu_x", status: "completed", summary: "done"),
        ])
        let event = TaskNotification.parseAll(in: Line.monitorEvent(taskId: "m1", event: "tick"))
        #expect(event == [TaskNotification(taskId: "m1", summary: "Monitor event: \"log\"", event: "tick")])
        #expect(event.first?.isProgressEvent == true)
        #expect(parsed.first?.isProgressEvent == false)
    }

    @Test func lastActivityTracksNewestTimestamp() throws {
        let result = try facts(from: [Line.prompt("Hej", at: 0), Line.text("a", at: 30), Line.turnDuration(at: 31)])
        #expect(result.lastRecordTimestamp == fixtureTime(31))
    }
}
