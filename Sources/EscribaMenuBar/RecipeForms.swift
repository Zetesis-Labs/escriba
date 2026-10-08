import EscribaCore
import EscribaEngine
import EscribaJSC
import EscribaSystemKit
import Synchronization
import Foundation
import SwiftUI

nonisolated final class RecipeForms: Sendable {
    private struct Entry {
        let fingerprint: String
        let lists: RecipeLists
        let load: RecipeFormLoad
    }

    private static let remembered = 16

    let id = UUID()
    private let recipe: Recipe
    private let cache = Mutex<[Entry]>([])

    init(recipe: Recipe) {
        self.recipe = recipe
    }

    func load(_ key: String) async -> RecipeFormLoad {
        let target: RecipeTarget
        let lists: RecipeLists
        do {
            target = try recipe.shelf.target(key)
            lists = try recipe.lists()
        } catch {
            return .problem("\(error)")
        }
        let fingerprint = target.package.fingerprint
        if let hit = cache.withLock({ $0.first { $0.fingerprint == fingerprint && $0.lists == lists } }) {
            return hit.load
        }
        let load = await offloaded {
            do {
                return recipeFormLoad(schema: try recipeFormSchema(target.package, lists: lists))
            } catch {
                return .problem("\(error)")
            }
        }
        cache.withLock { entries in
            entries.insert(Entry(fingerprint: fingerprint, lists: lists, load: load), at: 0)
            entries = Array(entries.prefix(Self.remembered))
        }
        return load
    }
}

extension EnvironmentValues {
    @Entry var recipeForms: RecipeForms? = nil
}
