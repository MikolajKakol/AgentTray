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
    /// Display group; `.dimmed` for old sessions regardless of their status,
    /// `.acknowledged` for waiting or uncertain sessions marked as seen.
    public var group: SessionGroup
    public var id: String { snapshot.id }
    public var isDimmed: Bool { group == .dimmed }
    public var isAcknowledged: Bool { group == .acknowledged }
    /// The session asks for attention and can be marked as seen.
    public var canAcknowledge: Bool { group == .waitingForYou || group == .uncertain }
}

extension SessionSnapshot {
    /// Identifies the moment the session last changed. An acknowledgement made at this
    /// marker lasts until the conversation moves forward. Neither file mtime nor the last
    /// record's timestamp is used: Claude Code appends titles, `last-prompt`, the away
    /// recap and other bookkeeping after a turn ends.
    public var acknowledgementMarker: Date {
        facts.lastSignificantTimestamp ?? facts.lastRecordTimestamp ?? lastActivity
    }
}

/// Which acknowledgements to keep after a scan. Those of sessions in the scan stay; those of
/// missing sessions stay while they are younger than `hideAfter`. A scan can miss a session
/// for a moment, e.g. right after launch, before a directory is readable, or while a pattern
/// matches nothing; dropping its acknowledgement then brings it back as waiting.
public func retainedAcknowledgements(
    _ acknowledged: [String: Date], sessions: [SessionSnapshot], thresholds: Thresholds, now: Date
) -> [String: Date] {
    let ids = Set(sessions.map(\.id))
    return acknowledged.filter { id, marker in
        ids.contains(id) || now.timeIntervalSince(marker) <= thresholds.hideAfter
    }
}

/// Acknowledgements as stored in `UserDefaults`. Seconds since the reference date are what
/// `Date` holds, so a marker reads back exactly; converting through 1970 does not.
public enum AcknowledgementStorage {
    public static func encode(_ acknowledged: [String: Date]) -> [String: Double] {
        acknowledged.mapValues(\.timeIntervalSinceReferenceDate)
    }

    public static func decode(_ stored: [String: Double]) -> [String: Date] {
        stored.mapValues(Date.init(timeIntervalSinceReferenceDate:))
    }
}

/// Sessions as the popover and the menu bar icon show them at a given moment.
public struct SessionListing: Sendable, Equatable {
    /// Visible sessions in display order.
    public var rows: [SessionRow]
    /// Sessions waiting for the user, excluding dimmed ones and those waiting
    /// shorter than `Thresholds.countWaitingAfter`.
    public var waitingCount: Int
    /// At least one non-dimmed session may be waiting for a permission prompt.
    public var hasUncertain: Bool

    /// `acknowledged` maps session ids to the `acknowledgementMarker` they were marked seen at.
    public init(sessions: [SessionSnapshot], thresholds: Thresholds, now: Date, acknowledged: [String: Date] = [:]) {
        rows = sessions.compactMap { snapshot in
            let age = SessionAge(lastActivity: snapshot.lastActivity, thresholds: thresholds, now: now)
            guard age != .hidden else { return nil }
            let status = classify(facts: snapshot.facts, settings: thresholds, now: now)
            var group = age == .dimmed ? .dimmed : status.group
            if group == .waitingForYou || group == .uncertain,
               let marker = acknowledged[snapshot.id],
               snapshot.acknowledgementMarker.timeIntervalSince(marker) <= Self.markerTolerance {
                group = .acknowledged
            }
            return SessionRow(snapshot: snapshot, status: status, group: group)
        }
        rows.sort { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            let lhsRank = Self.rankWithinGroup(lhs), rhsRank = Self.rankWithinGroup(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.snapshot.lastActivity != rhs.snapshot.lastActivity {
                // Seen sessions are a history: the newest on top.
                return lhs.group == .acknowledged
                    ? lhs.snapshot.lastActivity > rhs.snapshot.lastActivity
                    : lhs.snapshot.lastActivity < rhs.snapshot.lastActivity
            }
            return lhs.id < rhs.id
        }
        // The marker is when the conversation last moved: for a waiting session, when the wait began.
        waitingCount = rows.filter { row in
            row.group == .waitingForYou
                && now.timeIntervalSince(row.snapshot.acknowledgementMarker) >= thresholds.countWaitingAfter
        }.count
        hasUncertain = rows.contains { $0.group == .uncertain }
    }

    /// Transcript timestamps have millisecond precision, so two different markers are at
    /// least 1 ms apart. A stored marker can come back from `UserDefaults` a fraction of a
    /// nanosecond off (older versions stored seconds since 1970); that must still match.
    static let markerTolerance: TimeInterval = 0.0005

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
