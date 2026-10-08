public let recipeFormExport = "buildRecipeForm"

public struct RecipeForm: Sendable, Equatable {
    public let fields: [RecipeFormField]

    public init(fields: [RecipeFormField]) {
        self.fields = fields
    }
}

public struct RecipeFormOption: Sendable, Equatable {
    public let value: String
    public let label: String

    public init(value: String, label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

public struct RecipeFormField: Sendable, Equatable {
    public indirect enum Kind: Sendable, Equatable {
        case toggle
        case text(lines: Int)
        case number(minimum: Double?, maximum: Double?, integer: Bool)
        case choice([RecipeFormOption])
        case choices([RecipeFormOption])
        case group([RecipeFormField])
    }

    public let name: String
    public let label: String
    public let help: String?
    public let kind: Kind
    public let nullable: Bool
    public let required: Bool
    public let defaultValue: DataValue?

    public init(
        name: String, label: String? = nil, help: String? = nil, kind: Kind, nullable: Bool = false,
        required: Bool = false, defaultValue: DataValue? = nil
    ) {
        self.name = name
        self.label = label ?? name
        self.help = help
        self.kind = kind
        self.nullable = nullable
        self.required = required
        self.defaultValue = defaultValue
    }
}

public enum RecipeFormProblem: Error, Equatable, CustomStringConvertible {
    case notAnObject
    case unsupported(path: String, what: String)

    public var description: String {
        switch self {
        case .notAnObject:
            "\(recipeFormExport) tiene que devolver un objeto: z.object({ … })"
        case .unsupported(let path, let what):
            "el formulario no sabe pintar \(what) en «\(path)»"
        }
    }
}

public enum RecipeFormLoad: Sendable, Equatable {
    case noForm
    case form(RecipeForm)
    case problem(String)

    public var isProblem: Bool {
        if case .problem = self { true } else { false }
    }
}

public func recipeFormLoad(schema: String?) -> RecipeFormLoad {
    guard let schema else { return .noForm }
    do {
        return .form(try recipeForm(from: try parseData(schema)))
    } catch {
        return .problem("\(error)")
    }
}

public func recipeForm(from schema: DataValue) throws(RecipeFormProblem) -> RecipeForm {
    guard case .object = schema, schema["anyOf"] == nil, typeNames(schema["type"]) == ["object"] else {
        throw .notAnObject
    }
    return RecipeForm(fields: try fields(of: schema, path: []))
}

private func fields(of schema: DataValue, path: [String]) throws(RecipeFormProblem) -> [RecipeFormField] {
    if case .object = schema["additionalProperties"], properties(of: schema).isEmpty {
        throw .unsupported(path: path.joined(separator: "."), what: "un registro de claves libres (z.record)")
    }
    let required = Set((schema["required"].flatMap(arrayItems) ?? []).compactMap(\.text))
    var fields: [RecipeFormField] = []
    for property in properties(of: schema) {
        fields.append(try field(property, required: required.contains(property.name), path: path + [property.name]))
    }
    return fields
}

private func properties(of schema: DataValue) -> [DataField] {
    guard case .object(let fields) = schema["properties"] else { return [] }
    return fields
}

private func arrayItems(_ value: DataValue) -> [DataValue]? {
    guard case .array(let items) = value else { return nil }
    return items
}

private func typeNames(_ value: DataValue?) -> [String] {
    switch value {
    case .string(let name): [name]
    case .array(let names): names.compactMap(\.text)
    default: []
    }
}

private func field(_ property: DataField, required: Bool, path: [String]) throws(RecipeFormProblem) -> RecipeFormField {
    let node = property.value
    let (solid, nullable) = unwrapNull(node)
    var kind = try kind(of: solid, path: path)
    if case .text = kind { kind = .text(lines: textLines(node["lineas"] ?? solid["lineas"])) }
    return RecipeFormField(
        name: property.name, label: node["title"]?.text ?? solid["title"]?.text,
        help: node["description"]?.text ?? solid["description"]?.text, kind: kind,
        nullable: nullable, required: required, defaultValue: node["default"] ?? solid["default"])
}

public let maximumTextLines = 20

private func textLines(_ value: DataValue?) -> Int {
    guard case .number(let lines) = value, lines >= 1 else { return 1 }
    return Int(min(lines, Double(maximumTextLines)))
}

private func unwrapNull(_ node: DataValue) -> (DataValue, nullable: Bool) {
    if case .array(let branches) = node["anyOf"] {
        let solid = branches.filter { typeNames($0["type"]) != ["null"] }
        if solid.count == 1, solid.count < branches.count { return (solid[0], true) }
        return (node, solid.count < branches.count)
    }
    let enumNull = node["enum"].flatMap(arrayItems)?.contains(.null) ?? false
    return (node, typeNames(node["type"]).contains("null") || enumNull)
}

private func kind(of node: DataValue, path: [String]) throws(RecipeFormProblem) -> RecipeFormField.Kind {
    let place = path.joined(separator: ".")
    if node["$ref"] != nil { throw .unsupported(path: place, what: "un esquema recursivo ($ref)") }
    if let options = options(of: node) { return .choice(options) }
    if node["anyOf"] != nil || node["oneOf"] != nil || node["allOf"] != nil {
        throw .unsupported(path: place, what: "una unión de tipos distintos")
    }
    let types = typeNames(node["type"]).filter { $0 != "null" }
    guard types.count == 1, let type = types.first else {
        throw .unsupported(path: place, what: types.isEmpty ? "un valor sin tipo" : "una unión de tipos distintos")
    }
    switch type {
    case "boolean":
        return .toggle
    case "string":
        return .text(lines: 1)
    case "number", "integer":
        return .number(
            minimum: number(node["minimum"]), maximum: number(node["maximum"]), integer: type == "integer")
    case "array":
        if node["prefixItems"] != nil { throw .unsupported(path: place, what: "una tupla (z.tuple)") }
        guard let items = node["items"], let options = options(of: items) else {
            throw .unsupported(path: place, what: "una lista que no es de opciones (z.array de z.enum)")
        }
        return .choices(options)
    case "object":
        return .group(try fields(of: node, path: path))
    default:
        throw .unsupported(path: place, what: "el tipo «\(type)»")
    }
}

private func options(of node: DataValue) -> [RecipeFormOption]? {
    if case .object(let fields) = node["not"], fields.isEmpty { return [] }
    if let own = literalOptions(node) { return own }
    guard case .array(let branches) = node["anyOf"] ?? node["oneOf"] else { return nil }
    var options: [RecipeFormOption] = []
    for branch in branches where typeNames(branch["type"]) != ["null"] {
        guard let some = literalOptions(branch) else { return nil }
        options += some
    }
    return options
}

private func literalOptions(_ node: DataValue) -> [RecipeFormOption]? {
    if case .array(let values) = node["enum"] {
        let texts = values.compactMap(\.text)
        return texts.count == values.filter({ $0 != .null }).count ? texts.map { RecipeFormOption(value: $0) } : nil
    }
    guard let constant = node["const"]?.text else { return nil }
    return [RecipeFormOption(value: constant, label: node["title"]?.text)]
}

private func number(_ value: DataValue?) -> Double? {
    guard case .number(let number) = value else { return nil }
    return number
}

public struct RecipeFormSection: Sendable, Equatable, Identifiable {
    public let path: [String]
    public let title: String?
    public let fields: [RecipeFormField]

    public var id: [String] { path + [fields.first?.name ?? ""] }

    public init(path: [String], title: String?, fields: [RecipeFormField]) {
        self.path = path
        self.title = title
        self.fields = fields
    }
}

public func recipeFormSections(_ form: RecipeForm) -> [RecipeFormSection] {
    sections(form.fields, path: [], titles: [])
}

private func sections(_ fields: [RecipeFormField], path: [String], titles: [String]) -> [RecipeFormSection] {
    var result: [RecipeFormSection] = []
    var leaves: [RecipeFormField] = []
    let title = titles.isEmpty ? nil : titles.joined(separator: " · ")
    func closeLeaves() {
        if !leaves.isEmpty { result.append(RecipeFormSection(path: path, title: title, fields: leaves)) }
        leaves = []
    }
    for field in fields {
        guard case .group(let children) = field.kind else {
            leaves.append(field)
            continue
        }
        closeLeaves()
        result += sections(children, path: path + [field.name], titles: titles + [field.label])
    }
    closeLeaves()
    return result
}

public func recipeFormDefaults(_ form: RecipeForm) -> DataValue {
    defaults(of: form.fields)
}

private func defaults(of fields: [RecipeFormField]) -> DataValue {
    .object(fields.compactMap { field in
        defaultValue(of: field).map { DataField(name: field.name, value: $0) }
    })
}

private func defaultValue(of field: RecipeFormField) -> DataValue? {
    guard case .group(let children) = field.kind else { return field.defaultValue }
    switch field.defaultValue {
    case .object?: return overlay(defaults(of: children), with: field.defaultValue)
    case nil: return defaults(of: children)
    case let other?: return other
    }
}

public func recipeFormValues(_ form: RecipeForm, saved: DataValue?) -> DataValue {
    let base = recipeFormDefaults(form)
    guard case .object(let savedFields) = saved else { return base }
    let known = Set(form.fields.map(\.name))
    return overlay(base, with: .object(savedFields.filter { known.contains($0.name) }))
}

private func overlay(_ base: DataValue, with top: DataValue?) -> DataValue {
    guard case .object(var fields) = base, case .object(let changes)? = top else { return top ?? base }
    for change in changes {
        if let index = fields.firstIndex(where: { $0.name == change.name }) {
            fields[index] = DataField(name: change.name, value: overlay(fields[index].value, with: change.value))
        } else {
            fields.append(change)
        }
    }
    return .object(fields)
}

public func recipeFormOverrides(_ form: RecipeForm, values: DataValue) -> DataValue? {
    let changes = overrides(form.fields, values: values)
    return changes.isEmpty ? nil : .object(changes)
}

private func overrides(_ fields: [RecipeFormField], values: DataValue) -> [DataField] {
    fields.compactMap { field in
        let value = values[field.name]
        if case .group(let children) = field.kind, let value, case .object = value {
            let inner = overrides(children, values: value)
            if !inner.isEmpty { return DataField(name: field.name, value: .object(inner)) }
            return field.required && field.defaultValue == nil ? DataField(name: field.name, value: .object([])) : nil
        }
        guard let value, value != defaultValue(of: field) else { return nil }
        return DataField(name: field.name, value: value)
    }
}

public func recipeFormIssue(_ field: RecipeFormField, value: DataValue?) -> String? {
    guard let value else { return field.required && field.defaultValue == nil ? "falta un valor" : nil }
    if value == .null { return field.nullable ? nil : "falta un valor" }
    switch field.kind {
    case .choice(let options):
        guard let text = value.text else { return "no es una de las opciones" }
        return options.contains { $0.value == text } ? nil : "«\(text)» ya no está entre las opciones"
    case .choices(let options):
        guard case .array(let items) = value else { return "no es una lista de opciones" }
        let stale = items.compactMap(\.text).first { text in !options.contains { $0.value == text } }
        return stale.map { "«\($0)» ya no está entre las opciones" }
    case .number(let minimum, let maximum, let integer):
        guard case .number(let number) = value else { return "no es un número" }
        if integer, number != number.rounded() { return "tiene que ser un número entero" }
        if let minimum, let maximum, number < minimum || number > maximum {
            return "tiene que estar entre \(recipeFormNumberText(minimum)) y \(recipeFormNumberText(maximum))"
        }
        if let minimum, number < minimum { return "tiene que ser \(recipeFormNumberText(minimum)) o más" }
        if let maximum, number > maximum { return "tiene que ser \(recipeFormNumberText(maximum)) o menos" }
        return nil
    case .toggle, .text, .group:
        return nil
    }
}

public func recipeFormNumberText(_ number: Double) -> String {
    number == number.rounded() && abs(number) < 1e15 ? "\(Int(number))" : "\(number)"
}

public let maximumNumberChoices = 21

public func recipeFormNumberChoices(_ field: RecipeFormField) -> [Int]? {
    guard case .number(let minimum?, let maximum?, true) = field.kind,
        minimum <= maximum, abs(minimum) < 1e9, abs(maximum) < 1e9
    else { return nil }
    let range = Int(minimum.rounded(.up))...Int(maximum.rounded(.down))
    return range.count <= maximumNumberChoices ? Array(range) : nil
}

extension DataValue {
    public func value(at path: [String]) -> DataValue? {
        guard let first = path.first else { return self }
        return self[first]?.value(at: Array(path.dropFirst()))
    }

    public func setting(_ value: DataValue?, at path: [String]) -> DataValue {
        guard let first = path.first else { return value ?? self }
        var fields: [DataField]
        if case .object(let existing) = self { fields = existing } else { fields = [] }
        let index = fields.firstIndex { $0.name == first }
        let rest = Array(path.dropFirst())
        let child: DataValue? =
            rest.isEmpty ? value : (index.map { fields[$0].value } ?? .object([])).setting(value, at: rest)
        switch (index, child) {
        case (let index?, let child?): fields[index] = DataField(name: first, value: child)
        case (let index?, nil): fields.remove(at: index)
        case (nil, let child?): fields.append(DataField(name: first, value: child))
        case (nil, nil): break
        }
        return .object(fields)
    }
}
