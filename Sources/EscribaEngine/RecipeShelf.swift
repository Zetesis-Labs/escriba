import Foundation
import EscribaCore

public struct RecipeTarget: Sendable, Equatable {
    public let key: String
    public let name: String
    public let kind: RecipeKind
    public let package: RecipePackage
    public let parameters: DefaultRecipeSettings?

    public init(
        key: String, name: String, kind: RecipeKind, package: RecipePackage, parameters: DefaultRecipeSettings?
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.package = package
        self.parameters = parameters
    }

    public var info: RecipeInfo { RecipeInfo(key: key, name: name, kind: kind) }
}

public struct RecipeShelf: Sendable {
    public var recipes: @Sendable () throws -> [RecipeInfo]
    public var target: @Sendable (_ query: String?) throws -> RecipeTarget

    public init(
        recipes: @escaping @Sendable () throws -> [RecipeInfo],
        target: @escaping @Sendable (String?) throws -> RecipeTarget
    ) {
        self.recipes = recipes
        self.target = target
    }

    public static func only(_ target: RecipeTarget) -> RecipeShelf {
        RecipeShelf(recipes: { [target.info] }, target: { _ in target })
    }
}

public func recipeShelf(
    book: @escaping @Sendable () -> RecipeBook, installed: @escaping @Sendable () throws -> [String: InstalledRecipe],
    formPackage: RecipePackage
) -> RecipeShelf {
    @Sendable func available(_ book: RecipeBook, _ installed: [String: InstalledRecipe]) -> [RecipeInfo] {
        book.listing(code: installed.values.sorted { $0.key < $1.key }.map {
            RecipeCodeEntry(key: $0.key, name: $0.name)
        }).map { RecipeInfo(key: $0.key, name: $0.name, kind: $0.kind) }
    }

    @Sendable func target(_ key: String, in book: RecipeBook, installed: [String: InstalledRecipe]) -> RecipeTarget? {
        switch book.resolve(key, installed: installed) {
        case .form(let recipe):
            RecipeTarget(
                key: recipe.key, name: recipe.name, kind: .form,
                package: RecipePackage(key: recipe.key, source: formPackage.source, fingerprint: formPackage.fingerprint),
                parameters: recipe.settings)
        case .code(let package):
            RecipeTarget(
                key: package.key, name: package.name, kind: .code,
                package: RecipePackage(key: package.key, source: package.source, fingerprint: package.fingerprint),
                parameters: nil)
        case .missing:
            nil
        }
    }

    return RecipeShelf(
        recipes: { available(book(), try installed()) },
        target: { query in
            let (current, packages) = (book(), try installed())
            guard let query else {
                guard let found = target(current.defaultKey, in: current, installed: packages) else {
                    throw RecipeError.defaultUnavailable(current.defaultKey)
                }
                return found
            }
            let info = try recipeLookup(
                query, in: available(current, packages), kind: .recipe, key: \.key, name: \.name)
            guard let found = target(info.key, in: current, installed: packages) else {
                throw RecipeLookupError.missing(kind: .recipe, query: query)
            }
            return found
        })
}
