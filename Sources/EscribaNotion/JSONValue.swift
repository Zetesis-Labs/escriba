import Foundation

public enum JSONValue: Equatable, Sendable, Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var count: Int? {
        switch self {
        case .array(let items): items.count
        case .object(let fields): fields.count
        default: nil
        }
    }

    public var text: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .array(let items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case .object(let fields):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in fields { try container.encode(value, forKey: DynamicKey(key)) }
        }
    }
}

struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public func jsonValue(from any: Any) -> JSONValue {
    #if canImport(ObjectiveC)
    if let number = any as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
    }
    #endif
    return switch any {
    case let value as String: .string(value)
    case let value as Bool: .bool(value)
    case let value as Int: .number(Double(value))
    case let value as Double: .number(value)
    case let value as NSNumber: .number(value.doubleValue)
    case let value as [Any]: .array(value.map(jsonValue(from:)))
    case let value as [String: Any]: .object(value.mapValues(jsonValue(from:)))
    default: .null
    }
}
