import Foundation

public enum RecipeKind: String, Sendable, Equatable, Codable {
    case form = "formulario"
    case code = "codigo"
}

public struct FormRecipe: Sendable, Equatable, Codable, Identifiable {
    public let key: String
    public var name: String

    public var id: String { key }

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

private struct StoredFormRecipe: Decodable {
    let key: String
    let name: String
    let settings: DefaultRecipeSettings?

    enum CodingKeys: String, CodingKey {
        case key, name, settings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        settings = try? container.decodeIfPresent(DefaultRecipeSettings.self, forKey: .settings)
    }
}

public struct FormRecipeReading: Sendable, Equatable {
    public let stt: String?
    public let language: String?
    public let summarize: Bool
    public let llm: String?
    public let prompt: String?

    public init(stt: String?, language: String?, summarize: Bool, llm: String?, prompt: String?) {
        self.stt = stt
        self.language = language
        self.summarize = summarize
        self.llm = llm
        self.prompt = prompt
    }
}

public func formRecipeValues(_ settings: DefaultRecipeSettings) -> DataValue {
    let text = { (value: String?) in value.map(DataValue.string) ?? .null }
    return .object([
        DataField(name: "stt", value: .string(settings.stt)),
        DataField(name: "idioma", value: text(settings.language)),
        DataField(name: "hablantes", value: .object([
            DataField(name: "detectar", value: .bool(settings.detectSpeakers)),
            DataField(name: "cuantos", value: settings.speakerCount.map { .number(Double($0)) } ?? .null),
        ])),
        DataField(name: "resumir", value: .bool(settings.summarize)),
        DataField(name: "llm", value: .string(settings.llm)),
        DataField(name: "prompt", value: text(settings.prompt)),
        DataField(name: "conectores", value: .array(settings.connectors.map(DataValue.string))),
    ])
}

public struct RecipeCodeEntry: Sendable, Equatable {
    public let key: String
    public let name: String?

    public init(key: String, name: String?) {
        self.key = key
        self.name = name
    }
}

public struct RecipeListing: Sendable, Equatable, Identifiable {
    public let key: String
    public let name: String
    public let kind: RecipeKind
    public let isDefault: Bool

    public var id: String { key }

    public init(key: String, name: String, kind: RecipeKind, isDefault: Bool) {
        self.key = key
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
    }
}

public enum RecipeResolution: Sendable, Equatable {
    case form(FormRecipe)
    case code(InstalledRecipe)
    case missing(String)
}

public struct RecipeInfo: Sendable, Equatable, Encodable {
    public let key: String
    public let name: String
    public let kind: RecipeKind

    public init(key: String, name: String, kind: RecipeKind) {
        self.key = key
        self.name = name
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case key = "clave", name = "nombre", kind = "tipo"
    }
}

extension DefaultRecipeSettings {
    public static let standard = DefaultRecipeSettings(
        stt: "whisper", language: "es", detectSpeakers: false, speakerCount: nil, summarize: true, llm: "apple",
        prompt: nil, connectors: [])
}

public struct RecipeBook: Sendable, Equatable, Codable {
    public static let defaultName = "Por defecto"

    public private(set) var forms: [FormRecipe]
    public private(set) var defaultKey: String
    public private(set) var values: [String: String]

    public init(forms: [FormRecipe], defaultKey: String, values: [String: String] = [:]) {
        self.forms = forms.isEmpty ? [FormRecipe(key: "formulario", name: Self.defaultName)] : forms
        self.defaultKey = defaultKey
        self.values = values
    }

    public init(migrating settings: DefaultRecipeSettings, key: String) {
        self.init(
            forms: [FormRecipe(key: key, name: Self.defaultName)], defaultKey: key,
            values: [key: dataText(formRecipeValues(settings))])
    }

    private enum CodingKeys: String, CodingKey {
        case forms, defaultKey, values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([StoredFormRecipe].self, forKey: .forms)
        var values = try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        for form in stored where values[form.key] == nil {
            values[form.key] = form.settings.map { dataText(formRecipeValues($0)) }
        }
        self.init(
            forms: stored.map { FormRecipe(key: $0.key, name: $0.name) },
            defaultKey: try container.decode(String.self, forKey: .defaultKey), values: values)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(forms, forKey: .forms)
        try container.encode(defaultKey, forKey: .defaultKey)
        try container.encode(values, forKey: .values)
    }

    public func form(_ key: String) -> FormRecipe? {
        forms.first { $0.key == key }
    }

    @discardableResult
    public mutating func add(key: String, name: String) -> FormRecipe {
        let recipe = FormRecipe(key: key, name: nextRecipeName(name, taken: forms.map(\.name)))
        forms.append(recipe)
        return recipe
    }

    @discardableResult
    public mutating func duplicate(_ key: String, as newKey: String) -> FormRecipe? {
        guard let original = form(key) else { return nil }
        let copy = add(key: newKey, name: "\(original.name) (copia)")
        values[newKey] = values[key]
        return copy
    }

    public mutating func rename(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = forms.firstIndex(where: { $0.key == key }) else { return }
        forms[index].name = trimmed
    }

    public mutating func remove(_ key: String) {
        guard forms.count > 1, forms.contains(where: { $0.key == key }) else { return }
        forms.removeAll { $0.key == key }
        values[key] = nil
        if defaultKey == key { defaultKey = forms[0].key }
    }

    public mutating func makeDefault(_ key: String) {
        defaultKey = key
    }

    public mutating func setValues(_ json: String?, for key: String) {
        values[key] = json
    }

    public func forgettingResolver(_ key: String) -> RecipeBook {
        changingFormValues { values in
            ["stt", "llm"].reduce(values) { values, name in
                values[name] == .string(key) ? values.setting(nil, at: [name]) : values
            }
        }
    }

    public func forgettingConnector(_ key: String) -> RecipeBook {
        changingFormValues { values in
            guard case .array(let connectors)? = values["conectores"] else { return values }
            return values.setting(.array(connectors.filter { $0 != .string(key) }), at: ["conectores"])
        }
    }

    public func forgettingMissing(connectors: Set<String>, stts: Set<String>, llms: Set<String>) -> RecipeBook {
        changingFormValues { values in
            var values = values
            for (name, known) in [("stt", stts), ("llm", llms)] {
                if let key = values[name]?.text, !known.contains(key) { values = values.setting(nil, at: [name]) }
            }
            guard case .array(let chosen)? = values["conectores"] else { return values }
            let kept = chosen.filter { $0.text.map(connectors.contains) ?? false }
            return kept == chosen ? values : values.setting(.array(kept), at: ["conectores"])
        }
    }

    private func changingFormValues(_ change: (DataValue) -> DataValue) -> RecipeBook {
        var book = self
        for form in forms {
            guard let text = values[form.key], let current = try? parseData(text) else { continue }
            let changed = change(current)
            if changed != current { book.values[form.key] = dataText(changed) }
        }
        return book
    }

    public func reading(of key: String) -> FormRecipeReading {
        let values = form(key) == nil ? nil : self.values[key].flatMap { try? parseData($0) }
        return FormRecipeReading(
            stt: values?["stt"]?.text, language: values?["idioma"]?.text, summarize: values?["resumir"] == .bool(true),
            llm: values?["llm"]?.text, prompt: values?["prompt"]?.text)
    }

    public func listing(code: [RecipeCodeEntry]) -> [RecipeListing] {
        forms.map { RecipeListing(key: $0.key, name: $0.name, kind: .form, isDefault: $0.key == defaultKey) }
            + code.map {
                RecipeListing(key: $0.key, name: $0.name ?? $0.key, kind: .code, isDefault: $0.key == defaultKey)
            }
    }

    public func resolve(_ key: String, installed: [String: InstalledRecipe]) -> RecipeResolution {
        if let recipe = form(key) { return .form(recipe) }
        if let package = installed[key] { return .code(package) }
        return .missing(key)
    }
}

public func nextRecipeName(_ base: String, taken: [String]) -> String {
    let taken = Set(taken)
    guard taken.contains(base) else { return base }
    return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
}

public let recipeCallLimit = 4

public enum RecipeCallProblem: Error, Sendable, Equatable, CustomStringConvertible {
    case cycle([String])
    case tooDeep([String])

    public var description: String {
        switch self {
        case .cycle(let names):
            "las recetas se llaman en círculo: \(names.joined(separator: " → "))"
        case .tooDeep(let names):
            "demasiadas recetas encadenadas (como mucho \(recipeCallLimit)): \(names.joined(separator: " → "))"
        }
    }
}

public func recipeCallProblem(chain: [RecipeInfo], next: RecipeInfo) -> RecipeCallProblem? {
    let names = (chain + [next]).map(\.name)
    if chain.contains(where: { $0.key == next.key }) { return .cycle(names) }
    if chain.count >= recipeCallLimit { return .tooDeep(names) }
    return nil
}
