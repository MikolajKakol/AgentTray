import Foundation

public enum SessionAge: Sendable, Equatable {
    case fresh
    case dimmed
    case hidden

    public init(lastActivity: Date, thresholds: Thresholds, now: Date) {
        let age = now.timeIntervalSince(lastActivity)
        if age > thresholds.hideAfter {
            self = .hidden
        } else if age > thresholds.dimAfter {
            self = .dimmed
        } else {
            self = .fresh
        }
    }
}

public struct SessionRow: Sendable, Equatable, Identifiable {
    public var snapshot: SessionSnapshot
    public var status: SessionStatus
    /// Display group; `.dimmed` for old sessions regardless of their status.
    public var group: SessionGroup
    public var id: String { snapshot.id }
    public var isDimmed: Bool { group == .dimmed }
}

/// Sessions as the popover and the menu bar icon show them at a given moment.
public struct SessionListing: Sendable, Equatable {
    /// Visible sessions in display order.
    public var rows: [SessionRow]
    /// Sessions waiting for the user, excluding dimmed ones.
    public var waitingCount: Int
    /// At least one non-dimmed session may be waiting for a permission prompt.
    public var hasUncertain: Bool

    public init(sessions: [SessionSnapshot], thresholds: Thresholds, now: Date) {
        rows = sessions.compactMap { snapshot in
            let age = SessionAge(lastActivity: snapshot.lastActivity, thresholds: thresholds, now: now)
            guard age != .hidden else { return nil }
            let status = classify(facts: snapshot.facts, settings: thresholds, now: now)
            return SessionRow(snapshot: snapshot, status: status, group: age == .dimmed ? .dimmed : status.group)
        }
        rows.sort { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            let lhsRank = Self.rankWithinGroup(lhs), rhsRank = Self.rankWithinGroup(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.snapshot.lastActivity != rhs.snapshot.lastActivity {
                return lhs.snapshot.lastActivity < rhs.snapshot.lastActivity
            }
            return lhs.id < rhs.id
        }
        waitingCount = rows.filter { $0.group == .waitingForYou }.count
        hasUncertain = rows.contains { $0.group == .uncertain }
    }

    /// Questions come before plain "your turn" within the waiting group.
    private static func rankWithinGroup(_ row: SessionRow) -> Int {
        row.group == .waitingForYou && row.status == .askingQuestion ? 0 : 1
    }
}

/// Polish texts for the session row.
public enum StatusText {
    public static func label(for status: SessionStatus) -> String {
        switch status {
        case .askingQuestion: "zadaje pytanie"
        case .yourTurn: "czeka na Ciebie"
        case .thinking: "myśli"
        case .runningTool(_, let summary): "wykonuje: \(summary)"
        case .maybeAwaitingPermission(let name, _): "może czekać na zgodę: \(name)"
        case .waitingForSubagents(let count): "czeka na subagentów (\(count))"
        case .monitoring(let count): "monitoruje (\(count))"
        }
    }

    /// Second row line, e.g. "czeka na Ciebie · 4 min".
    public static func statusLine(for status: SessionStatus, lastActivity: Date, now: Date) -> String {
        "\(label(for: status)) · \(relative(now.timeIntervalSince(lastActivity)))"
    }

    /// "Nazwa: summary" shown instead of the last message while a tool call is open.
    public static func toolLine(for status: SessionStatus) -> String? {
        switch status {
        case let .runningTool(name, summary), let .maybeAwaitingPermission(name, summary):
            "\(name): \(summary)"
        default:
            nil
        }
    }

    public static func relative(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}
