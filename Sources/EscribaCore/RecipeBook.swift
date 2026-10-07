import Foundation

public enum RecipeKind: String, Sendable, Equatable, Codable {
    case form = "formulario"
    case code = "codigo"
}

public struct FormRecipe: Sendable, Equatable, Codable, Identifiable {
    public let key: String
    public var name: String
    public var settings: DefaultRecipeSettings

    public var id: String { key }

    public init(key: String, name: String, settings: DefaultRecipeSettings) {
        self.key = key
        self.name = name
        self.settings = settings
    }
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
        stt: "whisper", language: nil, detectSpeakers: false, speakerCount: nil, summarize: false, llm: "apple",
        prompt: nil, connectors: [])
}

public struct RecipeBook: Sendable, Equatable, Codable {
    public static let defaultName = "Por defecto"

    public private(set) var forms: [FormRecipe]
    public private(set) var defaultKey: String

    public init(forms: [FormRecipe], defaultKey: String) {
        self.forms = forms.isEmpty
            ? [FormRecipe(key: "formulario", name: Self.defaultName, settings: .standard)]
            : forms
        self.defaultKey = defaultKey
    }

    public init(migrating settings: DefaultRecipeSettings, key: String) {
        self.init(forms: [FormRecipe(key: key, name: Self.defaultName, settings: settings)], defaultKey: key)
    }

    private enum CodingKeys: String, CodingKey {
        case forms, defaultKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            forms: try container.decode([FormRecipe].self, forKey: .forms),
            defaultKey: try container.decode(String.self, forKey: .defaultKey))
    }

    public func form(_ key: String) -> FormRecipe? {
        forms.first { $0.key == key }
    }

    @discardableResult
    public mutating func add(key: String, name: String, settings: DefaultRecipeSettings) -> FormRecipe {
        let recipe = FormRecipe(key: key, name: nextRecipeName(name, taken: forms.map(\.name)), settings: settings)
        forms.append(recipe)
        return recipe
    }

    @discardableResult
    public mutating func duplicate(_ key: String, as newKey: String) -> FormRecipe? {
        guard let original = form(key) else { return nil }
        return add(key: newKey, name: "\(original.name) (copia)", settings: original.settings)
    }

    public mutating func rename(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = forms.firstIndex(where: { $0.key == key }) else { return }
        forms[index].name = trimmed
    }

    public mutating func update(_ key: String, settings: DefaultRecipeSettings) {
        guard let index = forms.firstIndex(where: { $0.key == key }) else { return }
        forms[index].settings = settings
    }

    public mutating func remove(_ key: String) {
        guard forms.count > 1, forms.contains(where: { $0.key == key }) else { return }
        forms.removeAll { $0.key == key }
        if defaultKey == key { defaultKey = forms[0].key }
    }

    public mutating func makeDefault(_ key: String) {
        defaultKey = key
    }

    public func forgettingResolver(_ key: String, stt: String, llm: String) -> RecipeBook {
        var book = self
        book.forms = forms.map { recipe in
            var recipe = recipe
            recipe.settings = recipe.settings.forgettingResolver(key, stt: stt, llm: llm)
            return recipe
        }
        return book
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
