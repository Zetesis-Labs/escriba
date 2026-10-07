import Foundation
import EscribaCore

public struct RecipeProjectSnapshot: Sendable, Equatable {
    public let paths: Set<String>
    public let sources: [String: String]

    public init(paths: Set<String>, sources: [String: String]) {
        self.paths = paths
        self.sources = sources
    }
}

public enum RecipeCompilation: Sendable, Equatable {
    case compiled(String, sourceMap: String?)
    case failed([RecipeBuildIssue])
}

public enum RecipeInspection: Sendable, Equatable {
    case valid(name: String)
    case invalid(String)
}

public struct RecipeToolchain: Sendable {
    public var compile: @Sendable (_ files: [String: String], _ entry: String) async throws -> RecipeCompilation
    public var inspect: @Sendable (_ source: String) async -> RecipeInspection
    public var fingerprint: @Sendable (_ source: String) -> String

    public init(
        compile: @escaping @Sendable ([String: String], String) async throws -> RecipeCompilation,
        inspect: @escaping @Sendable (String) async -> RecipeInspection,
        fingerprint: @escaping @Sendable (String) -> String
    ) {
        self.compile = compile
        self.inspect = inspect
        self.fingerprint = fingerprint
    }
}

public struct RecipeProjectDisk: Sendable {
    public var snapshot: @Sendable () throws -> RecipeProjectSnapshot
    public var write: @Sendable (_ path: String, _ contents: String) throws -> Void
    public var loadInstalled: @Sendable () throws -> [String: InstalledRecipe]
    public var saveInstalled: @Sendable ([String: InstalledRecipe]) throws -> Void

    public init(
        snapshot: @escaping @Sendable () throws -> RecipeProjectSnapshot,
        write: @escaping @Sendable (String, String) throws -> Void,
        loadInstalled: @escaping @Sendable () throws -> [String: InstalledRecipe],
        saveInstalled: @escaping @Sendable ([String: InstalledRecipe]) throws -> Void
    ) {
        self.snapshot = snapshot
        self.write = write
        self.loadInstalled = loadInstalled
        self.saveInstalled = saveInstalled
    }
}

public let recipeStatePath = ".escriba/estado.json"

@discardableResult
public func createRecipeProject(disk: RecipeProjectDisk) throws -> [String] {
    let template = templateWrites(paths: try disk.snapshot().paths)
    for file in template {
        try disk.write(file.path, file.contents)
    }
    return template.map(\.path)
}

public func rebuildRecipeProject(
    disk: RecipeProjectDisk, toolchain: RecipeToolchain, now: Date
) async throws -> RecipeBuildReport {
    let snapshot = try disk.snapshot()

    let paths = snapshot.paths.filter { !ignoredByRecipes($0) }
    let sources = snapshot.sources.filter { !ignoredByRecipes($0.key) }
    let previous = try disk.loadInstalled()
    var installed: [String: InstalledRecipe] = [:]
    var statuses: [RecipeStatus] = []
    for key in recipeKeys(in: paths) {
        let entry = paths.contains("recetas/\(key)/receta.ts") ? "recetas/\(key)/receta.ts" : "recetas/\(key)/receta.js"
        let outcome = await recipeOutcome(entry: entry, sources: sources, toolchain: toolchain)
        let step = nextInstalled(key: key, previous: previous[key], outcome: outcome, now: now)
        installed[key] = step.installed
        statuses.append(step.status)
    }
    try disk.saveInstalled(installed)

    let report = RecipeBuildReport(builtAt: now, recipes: statuses)
    try disk.write(recipeStatePath, try recipeBuildReportJSON(report))
    return report
}

private func recipeOutcome(
    entry: String, sources: [String: String], toolchain: RecipeToolchain
) async -> RecipeOutcome {
    let compilation: RecipeCompilation
    do {
        compilation = try await toolchain.compile(sources, entry)
    } catch {
        return .failed([RecipeBuildIssue(file: entry, text: "no se pudo compilar: \(error)")])
    }
    switch compilation {
    case .failed(let issues):
        return .failed(issues)
    case .compiled(let source, let sourceMap):
        switch await toolchain.inspect(source) {
        case .invalid(let problem):
            return .failed([RecipeBuildIssue(file: entry, text: problem)])
        case .valid(let name):
            return .valid(
                name: name, source: source, fingerprint: toolchain.fingerprint(source), sourceMap: sourceMap)
        }
    }
}
