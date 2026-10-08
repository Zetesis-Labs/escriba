public struct AnswerSchema: Sendable, Equatable {
    public indirect enum Kind: Sendable, Equatable {
        case string(choices: [String]?)
        case number
        case integer
        case boolean
        case array(AnswerSchema, minimum: Int?, maximum: Int?)
        case object([AnswerProperty])
    }

    public let kind: Kind
    public let description: String?
    public let nullable: Bool

    public init(_ kind: Kind, description: String? = nil, nullable: Bool = false) {
        self.kind = kind
        self.description = description
        self.nullable = nullable
    }
}

public struct AnswerProperty: Sendable, Equatable {
    public let name: String
    public let schema: AnswerSchema
    public let required: Bool

    public init(name: String, schema: AnswerSchema, required: Bool = true) {
        self.name = name
        self.schema = schema
        self.required = required
    }
}

public enum AnswerSchemaProblem: Error, Equatable, CustomStringConvertible {
    case notAnObject
    case unsupported(path: String, what: String)

    public var description: String {
        switch self {
        case .notAnObject:
            "el esquema de una pregunta tiene que ser un objeto (z.object)"
        case .unsupported(let path, let what):
            "el esquema usa \(what) en \(path.isEmpty ? "la raíz" : "«\(path)»"), y los LLM no saben responder a eso"
        }
    }
}

public func answerSchema(from json: DataValue) throws(AnswerSchemaProblem) -> AnswerSchema {
    guard case .object = json else { throw .notAnObject }
    let schema = try node(json, path: "")
    guard case .object = schema.kind, !schema.nullable else { throw .notAnObject }
    return schema
}

private func node(_ json: DataValue, path: String) throws(AnswerSchemaProblem) -> AnswerSchema {
    guard case .object = json else { throw .unsupported(path: path, what: "algo que no es un esquema") }
    let description = json["description"]?.text
    if json["$ref"] != nil { throw .unsupported(path: path, what: "un esquema recursivo ($ref)") }
    if json["allOf"] != nil || json["not"] != nil {
        throw .unsupported(path: path, what: "una combinación de esquemas (allOf o not)")
    }
    if case .array(let branches) = json["anyOf"] ?? json["oneOf"] {
        return try union(branches, description: description, path: path)
    }

    let types = typeNames(json["type"])
    var nullable = types.contains("null")
    let rest = types.filter { $0 != "null" }
    if case .array(let values) = json["enum"] {
        let choices = values.compactMap(\.text)
        nullable = nullable || values.contains(.null)
        guard choices.count == values.filter({ $0 != .null }).count, rest.allSatisfy({ $0 == "string" }) else {
            throw .unsupported(path: path, what: "un enumerado que no es de textos")
        }
        return AnswerSchema(.string(choices: choices), description: description, nullable: nullable)
    }
    if let constant = json["const"]?.text {
        return AnswerSchema(.string(choices: [constant]), description: description, nullable: nullable)
    }
    guard rest.count == 1, let type = rest.first else {
        throw .unsupported(path: path, what: rest.isEmpty ? "un valor sin tipo" : "una unión de tipos distintos")
    }
    return AnswerSchema(try kind(type, json, path: path), description: description, nullable: nullable)
}

private func typeNames(_ value: DataValue?) -> [String] {
    switch value {
    case .string(let name): [name]
    case .array(let names): names.compactMap(\.text)
    default: []
    }
}

private func union(
    _ branches: [DataValue], description: String?, path: String
) throws(AnswerSchemaProblem) -> AnswerSchema {
    let solid = branches.filter { typeNames($0["type"]) != ["null"] }
    let nullable = solid.count < branches.count
    if solid.count == 1 {
        let schema = try node(solid[0], path: path)
        return AnswerSchema(
            schema.kind, description: schema.description ?? description, nullable: schema.nullable || nullable)
    }
    var choices: [String] = []
    for branch in solid {
        guard case .string(let some?) = try node(branch, path: path).kind else {
            throw .unsupported(path: path, what: "una unión de tipos distintos")
        }
        choices += some
    }
    return AnswerSchema(.string(choices: choices), description: description, nullable: nullable)
}

private func kind(_ type: String, _ json: DataValue, path: String) throws(AnswerSchemaProblem) -> AnswerSchema.Kind {
    switch type {
    case "string": return .string(choices: nil)
    case "number": return .number
    case "integer": return .integer
    case "boolean": return .boolean
    case "array":
        if json["prefixItems"] != nil { throw .unsupported(path: path, what: "una tupla (z.tuple)") }
        guard let items = json["items"], case .object = items else {
            throw .unsupported(path: path, what: "una lista sin tipo de elementos")
        }
        return .array(
            try node(items, path: path + "[]"), minimum: wholeNumber(json["minItems"]),
            maximum: wholeNumber(json["maxItems"]))
    case "object":
        let declared: [DataField]
        if case .object(let fields) = json["properties"] {
            declared = fields
        } else {
            declared = []
        }
        if declared.isEmpty, case .object = json["additionalProperties"] {
            throw .unsupported(path: path, what: "un registro de claves libres (z.record)")
        }
        let required: [String]
        if case .array(let names) = json["required"] {
            required = names.compactMap(\.text)
        } else {
            required = []
        }
        var properties: [AnswerProperty] = []
        for field in declared {
            properties.append(AnswerProperty(
                name: field.name, schema: try node(field.value, path: path.isEmpty ? field.name : "\(path).\(field.name)"),
                required: required.contains(field.name)))
        }
        return .object(properties)
    default:
        throw .unsupported(path: path, what: "el tipo «\(type)»")
    }
}

private func wholeNumber(_ value: DataValue?) -> Int? {
    guard case .number(let number) = value, number >= 0, number == number.rounded(), number < 1e9 else { return nil }
    return Int(number)
}

public func jsonSchema(_ schema: AnswerSchema) -> DataValue {
    var fields: [DataField]
    switch schema.kind {
    case .object, .array:
        fields = solidSchema(schema)
        if schema.nullable {
            fields = [DataField(name: "anyOf", value: .array([.object(fields), .object([typeField("null")])]))]
            if let description = schema.description { fields.append(DataField(name: "description", value: .string(description))) }
        }
    default:
        fields = solidSchema(schema)
    }
    return .object(fields)
}

private func typeField(_ name: String, nullable: Bool = false) -> DataField {
    DataField(name: "type", value: nullable ? .array([.string(name), .string("null")]) : .string(name))
}

private func solidSchema(_ schema: AnswerSchema) -> [DataField] {
    let description = schema.description.map { DataField(name: "description", value: .string($0)) }
    let scalarNullable = schema.nullable
    switch schema.kind {
    case .string(let choices):
        var fields = [typeField("string", nullable: scalarNullable)]
        if let choices {
            let values = choices.map(DataValue.string) + (scalarNullable ? [.null] : [])
            fields.append(DataField(name: "enum", value: .array(values)))
        }
        return fields + [description].compactMap { $0 }
    case .number: return [typeField("number", nullable: scalarNullable)] + [description].compactMap { $0 }
    case .integer: return [typeField("integer", nullable: scalarNullable)] + [description].compactMap { $0 }
    case .boolean: return [typeField("boolean", nullable: scalarNullable)] + [description].compactMap { $0 }
    case .array(let items, let minimum, let maximum):
        var fields = [typeField("array")]
        if !schema.nullable, let description { fields.append(description) }
        fields.append(DataField(name: "items", value: jsonSchema(items)))
        if let minimum { fields.append(DataField(name: "minItems", value: .number(Double(minimum)))) }
        if let maximum { fields.append(DataField(name: "maxItems", value: .number(Double(maximum)))) }
        return fields
    case .object(let properties):
        var fields = [typeField("object")]
        if !schema.nullable, let description { fields.append(description) }
        fields.append(DataField(
            name: "properties",
            value: .object(properties.map { DataField(name: $0.name, value: jsonSchema($0.schema)) })))
        fields.append(DataField(
            name: "required", value: .array(properties.filter(\.required).map { .string($0.name) })))
        fields.append(DataField(name: "additionalProperties", value: .bool(false)))
        return fields
    }
}

public func isStrict(_ schema: AnswerSchema) -> Bool {
    switch schema.kind {
    case .object(let properties): properties.allSatisfy { $0.required && isStrict($0.schema) }
    case .array(let items, _, _): isStrict(items)
    default: true
    }
}

public func completingNulls(_ value: DataValue, for schema: AnswerSchema) -> DataValue {
    switch (value, schema.kind) {
    case (.object(let fields), .object(let properties)):
        var completed: [DataField] = []
        for property in properties {
            if let present = fields.first(where: { $0.name == property.name }) {
                completed.append(DataField(name: property.name, value: completingNulls(present.value, for: property.schema)))
            } else if property.schema.nullable {
                completed.append(DataField(name: property.name, value: .null))
            }
        }
        let known = Set(properties.map(\.name))
        return .object(completed + fields.filter { !known.contains($0.name) })
    case (.array(let items), .array(let itemSchema, _, _)):
        return .array(items.map { completingNulls($0, for: itemSchema) })
    default:
        return value
    }
}

public func answerObject(in text: String) throws(DataParseError) -> DataValue {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
        throw DataParseError(offset: 0, reason: "no hay ningún objeto JSON")
    }
    return try parseData(String(text[start...end]))
}
