import Foundation

/// One `sessions/<pid>.json` file. Only the fields AgentTray uses are decoded.
public struct SessionRegistryEntry: Sendable, Equatable, Decodable {
    /// The session currently open in this process. `/clear` and `/resume` rewrite it in place.
    public var sessionId: String
    public var name: String?
    /// `idle` or `busy`. Auxiliary only: the file outlives killed processes.
    public var status: String?
    public var updatedAt: Date?
    public var statusUpdatedAt: Date?
    /// Process id in `pidDomain`; for a container it means nothing on the host.
    public var pid: Int32?
    /// When the process started. Unchanged by `/clear` and `/resume`.
    public var startedAt: Date?
    /// `interactive` or `bg` (a background job without a terminal).
    public var kind: String?
    /// `cli` for a terminal session, `sdk-cli` for Speedwave Desktop.
    public var entrypoint: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, name, status, updatedAt, statusUpdatedAt, pid, startedAt, kind, entrypoint
    }

    public init(
        sessionId: String, name: String? = nil, status: String? = nil, updatedAt: Date? = nil,
        statusUpdatedAt: Date? = nil, pid: Int32? = nil, startedAt: Date? = nil,
        kind: String? = nil, entrypoint: String? = nil
    ) {
        self.sessionId = sessionId
        self.name = name
        self.status = status
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.pid = pid
        self.startedAt = startedAt
        self.kind = kind
        self.entrypoint = entrypoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        updatedAt = Self.millis(container, .updatedAt)
        statusUpdatedAt = Self.millis(container, .statusUpdatedAt)
        pid = try? container.decodeIfPresent(Int32.self, forKey: .pid)
        startedAt = Self.millis(container, .startedAt)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        entrypoint = try? container.decodeIfPresent(String.self, forKey: .entrypoint)
    }

    /// A process that may own a terminal window: not a background job, not Speedwave Desktop.
    public var isTerminalSession: Bool {
        kind != "bg" && (entrypoint == nil || entrypoint == "cli")
    }

    private static func millis(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        guard let value = try? container.decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    public static func decode(_ data: Data) throws -> SessionRegistryEntry {
        try JSONDecoder().decode(SessionRegistryEntry.self, from: data)
    }
}
