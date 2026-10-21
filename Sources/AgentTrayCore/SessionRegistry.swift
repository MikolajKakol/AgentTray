import Foundation

/// One `sessions/<pid>.json` file. Only the fields AgentTray uses are decoded.
public struct SessionRegistryEntry: Sendable, Equatable, Decodable {
    public var sessionId: String
    public var name: String?
    /// `idle` or `busy`. Auxiliary only: the file outlives killed processes.
    public var status: String?
    public var updatedAt: Date?
    public var statusUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sessionId, name, status, updatedAt, statusUpdatedAt
    }

    public init(sessionId: String, name: String? = nil, status: String? = nil, updatedAt: Date? = nil, statusUpdatedAt: Date? = nil) {
        self.sessionId = sessionId
        self.name = name
        self.status = status
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        updatedAt = Self.millis(container, .updatedAt)
        statusUpdatedAt = Self.millis(container, .statusUpdatedAt)
    }

    private static func millis(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        guard let value = try? container.decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    public static func decode(_ data: Data) throws -> SessionRegistryEntry {
        try JSONDecoder().decode(SessionRegistryEntry.self, from: data)
    }
}
