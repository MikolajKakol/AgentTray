import Foundation

/// One line of a Claude Code JSONL transcript, reduced to the fields AgentTray uses.
///
/// Unknown record types and unknown fields are ignored on purpose: the transcript
/// format changes between Claude Code versions.
public struct TranscriptRecord: Sendable, Equatable {
    public var timestamp: Date?
    public var cwd: String?
    public var kind: Kind

    public init(timestamp: Date? = nil, cwd: String? = nil, kind: Kind) {
        self.timestamp = timestamp
        self.cwd = cwd
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case user(UserRecord)
        case assistant(AssistantRecord)
        case turnDuration(pendingBackgroundAgentCount: Int?)
        case queueOperation(operation: String, notifications: [TaskNotification])
        case lastPrompt(String)
        case customTitle(String)
        case aiTitle(String)
        case permissionMode(String)
        /// Unknown type, sidechain record or a known type without the fields we need.
        case ignored
    }
}

public struct UserRecord: Sendable, Equatable {
    /// `origin.kind`, e.g. `human` or `task-notification`.
    public var originKind: String?
    public var isMeta: Bool
    /// `isCompactSummary`: the conversation summary Claude Code writes after compacting.
    public var isCompactSummary: Bool
    /// `message.content` when it is a string, or the joined `text` blocks otherwise.
    public var text: String?
    /// `tool_use_id` of every `tool_result` block.
    public var toolResultIds: [String]
    /// Background task started by the tool whose result this record carries.
    public var launchedBackgroundTask: BackgroundTask?
    /// Background task stopped by the `TaskStop` call whose result this record carries.
    /// A stopped task gets no `<task-notification>`.
    public var stoppedTaskId: String?
    /// The record says the user interrupted the turn (`[Request interrupted by user…`).
    public var isInterrupt: Bool
    public var notifications: [TaskNotification]

    public init(
        originKind: String? = nil,
        isMeta: Bool = false,
        isCompactSummary: Bool = false,
        text: String? = nil,
        toolResultIds: [String] = [],
        launchedBackgroundTask: BackgroundTask? = nil,
        stoppedTaskId: String? = nil,
        isInterrupt: Bool = false,
        notifications: [TaskNotification] = []
    ) {
        self.originKind = originKind
        self.isMeta = isMeta
        self.isCompactSummary = isCompactSummary
        self.text = text
        self.toolResultIds = toolResultIds
        self.launchedBackgroundTask = launchedBackgroundTask
        self.stoppedTaskId = stoppedTaskId
        self.isInterrupt = isInterrupt
        self.notifications = notifications
    }
}

public struct AssistantRecord: Sendable, Equatable {
    public var blocks: [AssistantBlock]
    /// `message.stop_reason`, repeated on every record of one response.
    public var stopReason: String?

    public init(blocks: [AssistantBlock], stopReason: String? = nil) {
        self.blocks = blocks
        self.stopReason = stopReason
    }
}

public enum AssistantBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, summary: String)
    case other
}

public struct BackgroundTask: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        /// A subagent started with `run_in_background`.
        case agent
        /// Any other background task, e.g. a background Bash command or a `Monitor`.
        case task
    }

    public var id: String
    public var kind: Kind
    /// How long the task may run before Claude Code kills it (`Monitor` only).
    public var timeout: TimeInterval?

    public init(id: String, kind: Kind, timeout: TimeInterval? = nil) {
        self.id = id
        self.kind = kind
        self.timeout = timeout
    }
}

/// Parsed `<task-notification>` block.
public struct TaskNotification: Sendable, Equatable {
    public var taskId: String?
    public var toolUseId: String?
    public var status: String?
    public var summary: String?
    /// `<event>`: one line of `Monitor` output, or the monitor's expiry notice.
    public var event: String?

    public init(taskId: String? = nil, toolUseId: String? = nil, status: String? = nil, summary: String? = nil, event: String? = nil) {
        self.taskId = taskId
        self.toolUseId = toolUseId
        self.status = status
        self.summary = summary
        self.event = event
    }

    /// A `Monitor` event: the task goes on running. Only the final notification
    /// carries `<status>`; an expired monitor reports it in `<event>` without one.
    public var isProgressEvent: Bool {
        guard status == nil, let event else { return false }
        return !event.hasPrefix("[Monitor expired")
    }

    /// Extracts every `<task-notification>` block from a message.
    public static func parseAll(in text: String) -> [TaskNotification] {
        var result: [TaskNotification] = []
        var searchRange = text.startIndex..<text.endIndex
        while let open = text.range(of: "<task-notification>", range: searchRange) {
            let bodyEnd = text.range(of: "</task-notification>", range: open.upperBound..<text.endIndex)
            let body = text[open.upperBound..<(bodyEnd?.lowerBound ?? text.endIndex)]
            result.append(TaskNotification(
                taskId: tag("task-id", in: body),
                toolUseId: tag("tool-use-id", in: body),
                status: tag("status", in: body),
                summary: tag("summary", in: body),
                event: tag("event", in: body)
            ))
            guard let bodyEnd else { break }
            searchRange = bodyEnd.upperBound..<text.endIndex
        }
        return result
    }

    private static func tag(_ name: String, in body: Substring) -> String? {
        guard let open = body.range(of: "<\(name)>"),
              let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex)
        else { return nil }
        return body[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriptParseError: Error, Equatable {
    case notJSONObject
}

extension TranscriptRecord {
    static let interruptPrefix = "[Request interrupted by user"

    /// Parses one JSONL line. Throws only when the line is not a JSON object;
    /// anything else that is not understood becomes `.ignored`.
    public static func parse(line: Data) throws -> TranscriptRecord {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line)
        } catch {
            throw TranscriptParseError.notJSONObject
        }
        guard let json = object as? [String: Any] else { throw TranscriptParseError.notJSONObject }
        return parse(json: json)
    }

    static func parse(json: [String: Any]) -> TranscriptRecord {
        var record = TranscriptRecord(
            timestamp: (json["timestamp"] as? String).flatMap(parseTimestamp),
            cwd: json["cwd"] as? String,
            kind: .ignored
        )
        if json["isSidechain"] as? Bool == true { return record }

        switch json["type"] as? String {
        case "user":
            record.kind = .user(parseUser(json))
        case "assistant":
            record.kind = .assistant(parseAssistant(json))
        case "system":
            if json["subtype"] as? String == "turn_duration" {
                record.kind = .turnDuration(pendingBackgroundAgentCount: intValue(json["pendingBackgroundAgentCount"]))
            }
        case "queue-operation":
            if let operation = json["operation"] as? String {
                let content = json["content"] as? String ?? ""
                record.kind = .queueOperation(operation: operation, notifications: TaskNotification.parseAll(in: content))
            }
        case "last-prompt":
            if let value = json["lastPrompt"] as? String { record.kind = .lastPrompt(value) }
        case "custom-title":
            if let value = json["customTitle"] as? String { record.kind = .customTitle(value) }
        case "ai-title":
            if let value = json["aiTitle"] as? String { record.kind = .aiTitle(value) }
        case "permission-mode":
            if let value = json["permissionMode"] as? String { record.kind = .permissionMode(value) }
        default:
            break
        }
        return record
    }

    private static func parseUser(_ json: [String: Any]) -> UserRecord {
        var user = UserRecord()
        user.originKind = (json["origin"] as? [String: Any])?["kind"] as? String
        user.isMeta = json["isMeta"] as? Bool ?? false
        user.isCompactSummary = json["isCompactSummary"] as? Bool ?? false

        let message = json["message"] as? [String: Any]
        var texts: [String] = []
        if let content = message?["content"] as? String {
            texts.append(content)
            user.text = content
        } else if let blocks = message?["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { user.toolResultIds.append(id) }
                    if let content = block["content"] as? String {
                        if content.hasPrefix(interruptPrefix) { user.isInterrupt = true }
                    } else if let inner = block["content"] as? [[String: Any]] {
                        for item in inner where (item["text"] as? String)?.hasPrefix(interruptPrefix) == true {
                            user.isInterrupt = true
                        }
                    }
                default:
                    break
                }
            }
            if !texts.isEmpty { user.text = texts.joined(separator: "\n") }
        }

        if texts.contains(where: { $0.hasPrefix(interruptPrefix) }) { user.isInterrupt = true }
        for text in texts where text.contains("<task-notification>") {
            user.notifications += TaskNotification.parseAll(in: text)
        }

        if let result = json["toolUseResult"] as? [String: Any] {
            if let id = result["backgroundTaskId"] as? String, !id.isEmpty {
                user.launchedBackgroundTask = BackgroundTask(id: id, kind: .task)
            } else if result["status"] as? String == "async_launched", let id = result["agentId"] as? String {
                user.launchedBackgroundTask = BackgroundTask(id: id, kind: .agent)
            } else if let id = result["taskId"] as? String, !id.isEmpty, let timeoutMs = intValue(result["timeoutMs"]) {
                // `Monitor`: `{"taskId", "timeoutMs", "persistent"}`.
                let timeout = result["persistent"] as? Bool == true ? nil : TimeInterval(timeoutMs) / 1000
                user.launchedBackgroundTask = BackgroundTask(id: id, kind: .task, timeout: timeout)
            } else if let id = result["task_id"] as? String, !id.isEmpty, result["task_type"] != nil {
                // `TaskStop`: `{"message", "task_id", "task_type", "command"}`.
                user.stoppedTaskId = id
            }
        }
        return user
    }

    private static func parseAssistant(_ json: [String: Any]) -> AssistantRecord {
        let message = json["message"] as? [String: Any]
        let blocks = (message?["content"] as? [[String: Any]] ?? []).map { block -> AssistantBlock in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String).map(AssistantBlock.text) ?? .other
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return .other }
                let input = block["input"] as? [String: Any] ?? [:]
                return .toolUse(id: id, name: name, summary: toolSummary(name: name, input: input))
            default:
                return .other
            }
        }
        return AssistantRecord(blocks: blocks, stopReason: message?["stop_reason"] as? String)
    }

    /// A prompt as the user typed it. Slash commands are stored as
    /// `<command-name>/x</command-name><command-args>y</command-args>`; they become `/x y`.
    public static func promptText(_ text: String) -> String {
        guard let name = tag("command-name", in: text) else { return text }
        let args = tag("command-args", in: text) ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short description of a tool call shown in the session row.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            if let command = input["command"] as? String, !command.isEmpty { return String(command.prefix(60)) }
        case "Read", "Edit", "Write":
            if let path = input["file_path"] as? String, !path.isEmpty {
                return (path as NSString).lastPathComponent
            }
        default:
            break
        }
        return name
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let number as NSNumber: return number.intValue
        default: return nil
        }
    }

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static func parseTimestamp(_ string: String) -> Date? {
        (try? fractionalStyle.parse(string)) ?? (try? plainStyle.parse(string))
    }
}
