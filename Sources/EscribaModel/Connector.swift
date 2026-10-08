import Foundation

nonisolated public struct Connector: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var destinationID: String?
    public var name: String
    public var provider: String
    public var accountID: UUID
    public var enabled: Bool
    public var configurationJSON: String
    public var programFingerprint: String?
    public var inputSchemaJSON: String?
    public var description: String?
    public var legacy: Bool
    public var migrationProblem: String?
    public var sourceMissing: Bool

    public init(id: UUID = UUID(), destinationID: String? = nil, name: String, provider: String,
                accountID: UUID, enabled: Bool = false, configurationJSON: String = "{}",
                programFingerprint: String? = nil, inputSchemaJSON: String? = nil,
                description: String? = nil, legacy: Bool = false, sourceMissing: Bool = false, migrationProblem: String? = nil) {
        self.id = id; self.destinationID = destinationID; self.name = name; self.provider = provider
        self.accountID = accountID; self.enabled = enabled; self.configurationJSON = configurationJSON
        self.programFingerprint = programFingerprint; self.inputSchemaJSON = inputSchemaJSON
        self.description = description; self.legacy = legacy; self.sourceMissing = sourceMissing
        self.migrationProblem = migrationProblem
    }
    public var key: String { destinationID ?? id.uuidString }
    public var isReady: Bool { !legacy && programFingerprint != nil }
    public var isLive: Bool { enabled && isReady && !sourceMissing }

    private enum CodingKeys: String, CodingKey {
        case id, destinationID, name, provider, accountID, enabled, configurationJSON
        case programFingerprint, inputSchemaJSON, description, legacy, sourceMissing, migrationProblem, kind
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        destinationID = try c.decodeIfPresent(String.self, forKey: .destinationID)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? c.decode(String.self, forKey: .kind)
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID) ?? id
        programFingerprint = try c.decodeIfPresent(String.self, forKey: .programFingerprint)
        inputSchemaJSON = try c.decodeIfPresent(String.self, forKey: .inputSchemaJSON)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        migrationProblem = try c.decodeIfPresent(String.self, forKey: .migrationProblem)
        sourceMissing = try c.decodeIfPresent(Bool.self, forKey: .sourceMissing) ?? false
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? c.contains(.kind)
        if let json = try c.decodeIfPresent(String.self, forKey: .configurationJSON) { configurationJSON = json }
        else {
            let all = try ConnectorJSON(from: decoder)
            let value: ConnectorJSON
            if case .object(let fields) = all { value = fields[provider] ?? .object([:]) }
            else { value = .object([:]) }
            configurationJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encodeIfPresent(destinationID, forKey: .destinationID)
        try c.encode(name, forKey: .name); try c.encode(provider, forKey: .provider)
        try c.encode(accountID, forKey: .accountID); try c.encode(enabled, forKey: .enabled)
        try c.encode(configurationJSON, forKey: .configurationJSON)
        try c.encodeIfPresent(programFingerprint, forKey: .programFingerprint)
        try c.encodeIfPresent(inputSchemaJSON, forKey: .inputSchemaJSON)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(migrationProblem, forKey: .migrationProblem)
        try c.encode(legacy, forKey: .legacy); try c.encode(sourceMissing, forKey: .sourceMissing)
    }
}

nonisolated public struct ConnectorAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: String
    public var capability: String
    public var origin: String?
    public var folder: String?
    public var enabled: Bool
    public var allowedHeaders: [String]
    public init(id: UUID = UUID(), name: String, provider: String, capability: String,
                origin: String? = nil, folder: String? = nil, enabled: Bool = true,
                allowedHeaders: [String] = ["content-type", "accept"]) {
        self.id = id; self.name = name; self.provider = provider; self.capability = capability
        self.origin = origin; self.folder = folder; self.enabled = enabled
        self.allowedHeaders = allowedHeaders
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, provider, capability, origin, folder, enabled, allowedHeaders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        capability = try c.decode(String.self, forKey: .capability)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowedHeaders = try c.decodeIfPresent([String].self, forKey: .allowedHeaders) ?? ["content-type", "accept"]
    }

}

nonisolated private indirect enum ConnectorJSON: Codable {
    case object([String: ConnectorJSON]), array([ConnectorJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: ConnectorJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([ConnectorJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
