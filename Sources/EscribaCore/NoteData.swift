public let maximumNoteDataBytes = 100_000

public enum NoteDataProblem: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case notAnObject
    case tooLarge(Int)

    public var description: String {
        switch self {
        case .invalid(let reason): "los datos de la nota \(reason)"
        case .notAnObject: "los datos de la nota tienen que ser un objeto, o null para no guardar ninguno"
        case .tooLarge(let bytes):
            "los datos de la nota ocupan \(bytes / 1000) KB y el máximo son \(maximumNoteDataBytes / 1000) KB"
        }
    }
}

public func noteData(_ text: String) throws(NoteDataProblem) -> DataValue? {
    let bytes = text.utf8.count
    guard bytes <= maximumNoteDataBytes else { throw .tooLarge(bytes) }
    let value: DataValue
    do {
        value = try parseData(text)
    } catch {
        throw .invalid("\(error)")
    }
    switch value {
    case .null: return nil
    case .object: return value
    default: throw .notAnObject
    }
}

public struct DataRow: Sendable, Equatable {
    public let label: String
    public let depth: Int
    public let value: DataRowValue

    public init(label: String, depth: Int, value: DataRowValue) {
        self.label = label
        self.depth = depth
        self.value = value
    }
}

public enum DataRowValue: Sendable, Equatable {
    case text(String)
    case list([String])
    case group
}

public func dataRows(_ value: DataValue, schema: DataValue? = nil) -> [DataRow] {
    guard case .object(let fields) = value else { return [] }
    return fields.flatMap { field(of: $0, in: schema, depth: 0) }
}

private let emptyValue = "—"

private func field(of field: DataField, in schema: DataValue?, depth: Int) -> [DataRow] {
    let node = solid(schema)?["properties"]?[field.name]
    return rows(label: title(of: node) ?? field.name, value: field.value, schema: node, depth: depth)
}

private func solid(_ node: DataValue?) -> DataValue? {
    guard case .array(let branches) = node?["anyOf"] else { return node }
    return branches.first { $0["type"]?.text != "null" }
}

private func title(of node: DataValue?) -> String? {
    node?["title"]?.text ?? solid(node)?["title"]?.text
}

private func rows(label: String, value: DataValue, schema: DataValue?, depth: Int) -> [DataRow] {
    switch value {
    case .null:
        return []
    case .object(let fields):
        let children = fields.flatMap { field(of: $0, in: schema, depth: depth + 1) }
        return children.isEmpty ? [] : [DataRow(label: label, depth: depth, value: .group)] + children
    case .array(let items):
        let scalars = items.compactMap(scalarText)
        if scalars.count == items.count {
            return scalars.isEmpty ? [] : [DataRow(label: label, depth: depth, value: .list(scalars))]
        }
        let itemSchema = solid(schema)?["items"]
        return items.enumerated().flatMap { index, item in
            rows(label: "\(label) \(index + 1)", value: item, schema: itemSchema, depth: depth)
        }
    default:
        return [DataRow(label: label, depth: depth, value: .text(scalarText(value) ?? emptyValue))]
    }
}

private func scalarText(_ value: DataValue) -> String? {
    switch value {
    case .null: emptyValue
    case .bool(let flag): flag ? "sí" : "no"
    case .number(let number): String(dataText(.number(number)).map { $0 == "." ? "," : $0 })
    case .string(let text): text
    case .array, .object: nil
    }
}
