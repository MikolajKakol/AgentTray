import Foundation

/// A tool call that has no result yet.
public struct OpenToolUse: Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var timestamp: Date?
    /// Order in which the call appeared; breaks ties between equal timestamps.
    public var sequence: Int

    public init(id: String, name: String, summary: String, timestamp: Date?, sequence: Int) {
        self.id = id
        self.name = name
        self.summary = summary
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

/// Intermediate facts about a session, built by reducing transcript records in order.
/// See "Model stanów / Fakty pośrednie" in SPEC.md.
public struct SessionFacts: Sendable, Equatable {
    public var openToolUses: [String: OpenToolUse] = [:]
    /// Background tasks started and not yet finished, by task id.
    public var backgroundTasks: [String: BackgroundTask.Kind] = [:]
    /// When Claude Code kills a background task that has a timeout (`Monitor`).
    /// Covers a lost expiry notification.
    public var backgroundTaskDeadlines: [String: Date] = [:]
    public var pendingBackgroundAgents = 0
    /// Ids of tasks already reported finished. A notification shows up twice
    /// (queued, then delivered); this keeps `pendingBackgroundAgents` from dropping twice.
    public var finishedTaskIds: Set<String> = []
    public var turnEnded = false
    public var permissionMode: String?
    public var lastRecordTimestamp: Date?
    /// Timestamp of the last record that moved the conversation forward: a human prompt,
    /// a tool result, an interrupt, an `assistant` record, `turn_duration` or a task notification.
    /// Bookkeeping appended later (away recap, compaction, hook summaries, attachments) does not count.
    public var lastSignificantTimestamp: Date?
    /// Value of the latest `last-prompt` record.
    public var lastPromptRecord: String?
    /// Text of the latest human prompt; fallback when there is no `last-prompt`.
    public var lastHumanPrompt: String?
    /// Text of the first human prompt; title fallback for sessions without a title record.
    public var firstHumanPrompt: String?
    public var lastMessage: String?
    public var customTitle: String?
    public var aiTitle: String?
    public var cwd: String?
    var nextSequence = 0

    public init() {}

    public var lastPrompt: String? { lastPromptRecord ?? lastHumanPrompt }

    /// The transcript part of the title; the caller falls back to the registry name and session id.
    public var transcriptTitle: String? { customTitle ?? aiTitle }
}

public enum SessionStatus: Sendable, Equatable {
    case askingQuestion
    case waitingForSubagents(Int)
    case runningTool(name: String, summary: String)
    case maybeAwaitingPermission(name: String, summary: String)
    case monitoring(Int)
    case yourTurn
    case thinking

    public var group: SessionGroup {
        switch self {
        case .askingQuestion, .yourTurn: .waitingForYou
        case .maybeAwaitingPermission: .uncertain
        case .waitingForSubagents, .runningTool, .monitoring, .thinking: .working
        }
    }
}

public enum SessionGroup: Int, Sendable, Comparable, CaseIterable {
    case waitingForYou
    case uncertain
    case working
    /// Waiting or uncertain sessions the user marked as seen; not counted in the menu bar.
    case acknowledged
    case dimmed

    public static func < (lhs: SessionGroup, rhs: SessionGroup) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Thresholds: Sendable, Equatable {
    /// Sessions idle longer than this are dimmed and not counted in the menu bar.
    public var dimAfter: TimeInterval
    /// Sessions idle longer than this are hidden.
    public var hideAfter: TimeInterval
    /// A tool call running this long outside bypass mode may be waiting for permission.
    public var uncertainAfter: TimeInterval

    public init(dimAfter: TimeInterval = 10 * 3600, hideAfter: TimeInterval = 40 * 3600, uncertainAfter: TimeInterval = 10) {
        self.dimAfter = dimAfter
        self.hideAfter = hideAfter
        self.uncertainAfter = uncertainAfter
    }

    public static let `default` = Thresholds()
}

let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
let subagentTools: Set<String> = ["Agent", "Task"]

public func reduce(state: SessionFacts, record: TranscriptRecord) -> SessionFacts {
    var facts = state
    if let timestamp = record.timestamp {
        facts.lastRecordTimestamp = max(facts.lastRecordTimestamp ?? timestamp, timestamp)
        if record.advancesSession {
            facts.lastSignificantTimestamp = max(facts.lastSignificantTimestamp ?? timestamp, timestamp)
        }
    }
    if let cwd = record.cwd, !cwd.isEmpty { facts.cwd = cwd }

    switch record.kind {
    case .user(let user):
        for id in user.toolResultIds { facts.openToolUses[id] = nil }
        if let task = user.launchedBackgroundTask, !facts.finishedTaskIds.contains(task.id) {
            facts.backgroundTasks[task.id] = task.kind
            if let timeout = task.timeout, let timestamp = record.timestamp {
                facts.backgroundTaskDeadlines[task.id] = timestamp.addingTimeInterval(timeout)
            }
        }
        if let id = user.stoppedTaskId { facts.finish(taskId: id, summary: nil) }
        for notification in user.notifications { facts.finish(notification) }

        if user.isMeta || user.isCompactSummary { break }
        if user.isInterrupt {
            facts.turnEnded = true
        } else if user.originKind == "human" {
            facts.turnEnded = false
            if let text = user.text.map(TranscriptRecord.promptText) {
                facts.lastHumanPrompt = text
                if facts.firstHumanPrompt == nil { facts.firstHumanPrompt = text }
            }
        } else if user.originKind == "task-notification" {
            facts.turnEnded = false
        }

    case .assistant(let assistant):
        facts.turnEnded = false
        for block in assistant.blocks {
            switch block {
            case .text(let text):
                facts.lastMessage = text
            case let .toolUse(id, name, summary):
                facts.openToolUses[id] = OpenToolUse(
                    id: id, name: name, summary: summary,
                    timestamp: record.timestamp, sequence: facts.nextSequence
                )
                facts.nextSequence += 1
            case .other:
                break
            }
        }
        // Desktop app sessions (`sdk-cli`, `remote_desktop`) never write `turn_duration`;
        // there the final answer's `end_turn` is the only end-of-turn signal.
        if assistant.stopReason == "end_turn" || assistant.stopReason == "stop_sequence",
           facts.openToolUses.isEmpty {
            facts.turnEnded = true
        }

    case .turnDuration(let pending):
        facts.turnEnded = true
        facts.pendingBackgroundAgents = pending ?? 0

    case .queueOperation(_, let notifications):
        for notification in notifications { facts.finish(notification) }

    case .lastPrompt(let prompt):
        facts.lastPromptRecord = TranscriptRecord.promptText(prompt)
    case .customTitle(let title):
        facts.customTitle = title
    case .aiTitle(let title):
        facts.aiTitle = title
    case .permissionMode(let mode):
        facts.permissionMode = mode
    case .ignored:
        break
    }
    return facts
}

extension TranscriptRecord {
    var advancesSession: Bool {
        switch kind {
        case .user(let user): user.advancesSession
        case .assistant, .turnDuration: true
        case .queueOperation(_, let notifications): !notifications.isEmpty
        case .lastPrompt, .customTitle, .aiTitle, .permissionMode, .ignored: false
        }
    }
}

extension UserRecord {
    /// Only `user` records with a known role count. Claude Code also writes `user` records
    /// on its own while the session is idle, e.g. the summary after compaction.
    var advancesSession: Bool {
        guard !isMeta, !isCompactSummary else { return false }
        return originKind == "human" || originKind == "task-notification"
            || !toolResultIds.isEmpty || isInterrupt || !notifications.isEmpty
    }
}

extension SessionFacts {
    fileprivate mutating func finish(_ notification: TaskNotification) {
        guard let id = notification.taskId, !notification.isProgressEvent else { return }
        finish(taskId: id, summary: notification.summary)
    }

    fileprivate mutating func finish(taskId id: String, summary: String?) {
        guard !finishedTaskIds.contains(id) else { return }
        finishedTaskIds.insert(id)
        backgroundTaskDeadlines[id] = nil
        let kind = backgroundTasks.removeValue(forKey: id)
        let isAgent = kind == .agent || (kind == nil && summary?.hasPrefix("Agent ") == true)
        if isAgent, pendingBackgroundAgents > 0 {
            pendingBackgroundAgents -= 1
        }
    }
}

public func classify(facts: SessionFacts, settings: Thresholds, now: Date) -> SessionStatus {
    let open = facts.openToolUses.values.sorted { lhs, rhs in
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?) where l != r: l < r
        default: lhs.sequence < rhs.sequence
        }
    }

    if open.contains(where: { questionTools.contains($0.name) }) {
        return .askingQuestion
    }

    let subagents = open.filter { subagentTools.contains($0.name) }.count
    if subagents > 0 { return .waitingForSubagents(subagents) }
    if facts.turnEnded && facts.pendingBackgroundAgents > 0 {
        return .waitingForSubagents(facts.pendingBackgroundAgents)
    }

    if let tool = open.first {
        let elapsed = tool.timestamp.map { now.timeIntervalSince($0) } ?? 0
        if facts.permissionMode == "bypassPermissions" || elapsed < settings.uncertainAfter {
            return .runningTool(name: tool.name, summary: tool.summary)
        }
        return .maybeAwaitingPermission(name: tool.name, summary: tool.summary)
    }

    if facts.turnEnded {
        let tasks = facts.backgroundTasks.filter { id, kind in
            kind == .task && (facts.backgroundTaskDeadlines[id].map { $0 > now } ?? true)
        }.count
        return tasks > 0 ? .monitoring(tasks) : .yourTurn
    }
    return .thinking
}
