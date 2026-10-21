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

    @Test func parsesTaskNotifications() {
        let text = "przed " + Line.notification(taskId: "a1", summary: "Agent \"x\" completed") + " po " + Line.notification(taskId: "b2")
        let parsed = TaskNotification.parseAll(in: text)
        #expect(parsed == [
            TaskNotification(taskId: "a1", toolUseId: "toolu_x", status: "completed", summary: "Agent \"x\" completed"),
            TaskNotification(taskId: "b2", toolUseId: "toolu_x", status: "completed", summary: "done"),
        ])
    }

    @Test func lastActivityTracksNewestTimestamp() throws {
        let result = try facts(from: [Line.prompt("Hej", at: 0), Line.text("a", at: 30), Line.turnDuration(at: 31)])
        #expect(result.lastRecordTimestamp == fixtureTime(31))
    }
}
