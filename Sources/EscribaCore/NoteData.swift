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

public func dataRows(_ value: DataValue) -> [DataRow] {
    guard case .object(let fields) = value else { return [] }
    return fields.flatMap { rows(label: $0.name, value: $0.value, depth: 0) }
}

private let emptyValue = "—"

private func rows(label: String, value: DataValue, depth: Int) -> [DataRow] {
    switch value {
    case .object(let fields):
        return [DataRow(label: label, depth: depth, value: .group)]
            + fields.flatMap { rows(label: $0.name, value: $0.value, depth: depth + 1) }
    case .array(let items) where items.isEmpty:
        return [DataRow(label: label, depth: depth, value: .text(emptyValue))]
    case .array(let items):
        let scalars = items.compactMap(scalarText)
        if scalars.count == items.count { return [DataRow(label: label, depth: depth, value: .list(scalars))] }
        return items.enumerated().flatMap { index, item in
            rows(label: "\(label) \(index + 1)", value: item, depth: depth)
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
