import Foundation

public indirect enum PluginJSON: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginJSON])
    case object([String: PluginJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PluginJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(encoding value: some Encodable) throws {
        self = try pluginJSONDecoder().decode(PluginJSON.self, from: try pluginJSONEncoder().encode(value))
    }

    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try pluginJSONDecoder().decode(type, from: try pluginJSONEncoder().encode(self))
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [PluginJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: PluginJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    public subscript(path: String) -> PluginJSON {
        get { value(at: segments(path)) }
        set { set(newValue, at: segments(path)) }
    }

    public func text(_ path: String) -> String {
        self[path].string ?? ""
    }

    private func segments(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private func value(at path: [Substring]) -> PluginJSON {
        guard let head = path.first else { return self }
        let rest = Array(path.dropFirst())
        switch self {
        case .object(let members):
            return members[String(head)]?.value(at: rest) ?? .null
        case .array(let items):
            guard let index = Int(head), items.indices.contains(index) else { return .null }
            return items[index].value(at: rest)
        default:
            return .null
        }
    }

    private mutating func set(_ newValue: PluginJSON, at path: [Substring]) {
        guard let head = path.first else {
            self = newValue
            return
        }
        let rest = Array(path.dropFirst())
        if let index = Int(head) {
            var items = array ?? []
            while items.count <= index { items.append(.null) }
            items[index].set(newValue, at: rest)
            self = .array(items)
        } else {
            var members = object ?? [:]
            var child = members[String(head)] ?? .null
            child.set(newValue, at: rest)
            members[String(head)] = child
            self = .object(members)
        }
    }
}
