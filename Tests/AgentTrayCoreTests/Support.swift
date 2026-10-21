import Foundation
@testable import AgentTrayCore

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures")

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func facts(_ name: String) throws -> SessionFacts {
        let reader = TranscriptReader(url: url(name))
        try reader.update()
        return reader.facts
    }
}

/// `2026-10-21T10:00:00Z` plus an offset; fixture timestamps start there.
func fixtureTime(_ seconds: TimeInterval = 0) -> Date {
    TranscriptRecord.parseTimestamp("2026-10-21T10:00:00.000Z")!.addingTimeInterval(seconds)
}

/// A fresh temporary directory, removed when the value is deinitialized.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenttray-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let directory = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func append(_ relative: String, _ contents: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}

/// Builders for synthetic transcript lines.
enum Line {
    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func ts(_ seconds: TimeInterval) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(fixtureTime(seconds))
    }

    static func prompt(_ text: String, at seconds: TimeInterval = 0) -> String {
        json(["type": "user", "timestamp": ts(seconds), "cwd": "/workspace",
              "message": ["role": "user", "content": text], "origin": ["kind": "human"]])
    }

    static func lastPrompt(_ text: String) -> String {
        json(["type": "last-prompt", "lastPrompt": text])
    }

    static func aiTitle(_ text: String) -> String {
        json(["type": "ai-title", "aiTitle": text])
    }

    static func text(_ text: String, at seconds: TimeInterval = 1) -> String {
        json(["type": "assistant", "timestamp": ts(seconds),
              "message": ["role": "assistant", "content": [["type": "text", "text": text]], "stop_reason": "end_turn"]])
    }

    static func toolUse(_ id: String, _ name: String, input: [String: Any] = [:], at seconds: TimeInterval = 1) -> String {
        json(["type": "assistant", "timestamp": ts(seconds),
              "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
                          "stop_reason": "tool_use"]])
    }

    static func toolResult(_ id: String, at seconds: TimeInterval = 2, toolUseResult: [String: Any] = [:], content: String = "ok") -> String {
        json(["type": "user", "timestamp": ts(seconds),
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content]]],
              "toolUseResult": toolUseResult])
    }

    static func turnDuration(at seconds: TimeInterval = 3, pending: Int? = nil) -> String {
        var object: [String: Any] = ["type": "system", "subtype": "turn_duration", "durationMs": 1000, "timestamp": ts(seconds)]
        if let pending { object["pendingBackgroundAgentCount"] = pending }
        return json(object)
    }

    static func notification(taskId: String, summary: String = "done") -> String {
        "<task-notification>\n<task-id>\(taskId)</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n<status>completed</status>\n<summary>\(summary)</summary>\n</task-notification>"
    }

    static func enqueue(_ content: String, at seconds: TimeInterval = 10) -> String {
        json(["type": "queue-operation", "operation": "enqueue", "timestamp": ts(seconds), "content": content])
    }

    static func queueDequeue(at seconds: TimeInterval) -> String {
        json(["type": "queue-operation", "operation": "dequeue", "timestamp": ts(seconds)])
    }

    static func taskNotificationPrompt(_ content: String, at seconds: TimeInterval = 11) -> String {
        json(["type": "user", "timestamp": ts(seconds), "message": ["role": "user", "content": content],
              "origin": ["kind": "task-notification"]])
    }
}

func facts(from lines: [String]) throws -> SessionFacts {
    try lines.joined().split(separator: "\n").reduce(SessionFacts()) { state, line in
        reduce(state: state, record: try TranscriptRecord.parse(line: Data(line.utf8)))
    }
}
