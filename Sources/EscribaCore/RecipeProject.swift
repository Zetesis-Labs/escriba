import Foundation

public func recipeKeys(in paths: Set<String>) -> [String] {
    let keys = paths.compactMap { path -> String? in
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "recetas", ["receta.ts", "receta.js"].contains(parts[2]) else {
            return nil
        }
        return String(parts[1])
    }
    return Array(Set(keys)).sorted()
}

public func ignoredByRecipes(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    guard let first = parts.first else { return true }
    return [".escriba", ".git", "node_modules"].contains(first) || parts.last == ".DS_Store"
}

public struct RecipeProjectFile: Sendable, Equatable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public func templateWrites(paths: Set<String>, contents: [String: String]) -> [RecipeProjectFile] {
    let maintained = [
        RecipeProjectFile(path: "escriba-recetas.d.ts", contents: RecipeTemplate.contract + "\n"),
        RecipeProjectFile(path: "tsconfig.json", contents: RecipeTemplate.tsconfig + "\n"),
    ]
    let userOwned = [
        RecipeProjectFile(path: "AGENTS.md", contents: RecipeTemplate.agents + "\n"),
        RecipeProjectFile(path: "CLAUDE.md", contents: "@AGENTS.md\n"),
        RecipeProjectFile(path: ".gitignore", contents: ".escriba/\nnode_modules/\n.DS_Store\n"),
    ]
    let isNewProject = !paths.contains("escriba-recetas.d.ts") && recipeKeys(in: paths).isEmpty
    let starter = isNewProject
        ? [RecipeProjectFile(path: "recetas/mi-receta/receta.ts", contents: RecipeTemplate.starter + "\n")]
        : []
    return maintained.filter { contents[$0.path] != $0.contents }
        + (userOwned + starter).filter { !paths.contains($0.path) }
}

public struct InstalledRecipe: Sendable, Equatable, Codable {
    public let key: String
    public let name: String
    public let source: String
    public let fingerprint: String
    public let installedAt: Date

    public init(key: String, name: String, source: String, fingerprint: String, installedAt: Date) {
        self.key = key
        self.name = name
        self.source = source
        self.fingerprint = fingerprint
        self.installedAt = installedAt
    }
}

public struct RecipeBuildIssue: Sendable, Equatable, Codable {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let text: String

    public init(file: String? = nil, line: Int? = nil, column: Int? = nil, text: String) {
        self.file = file
        self.line = line
        self.column = column
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case file = "fichero", line = "linea", column = "columna", text = "texto"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
        try container.encode(text, forKey: .text)
    }

    public var location: String? {
        guard let file else { return nil }
        return [file, line.map(String.init), column.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }
}

public enum RecipeOutcome: Sendable, Equatable {
    case valid(name: String, source: String, fingerprint: String)
    case failed([RecipeBuildIssue])
}

public struct RecipeStatus: Sendable, Equatable, Codable {
    public let key: String
    public let name: String?
    public let active: String?
    public let activeSince: Date?
    public let issues: [RecipeBuildIssue]

    public init(key: String, name: String?, active: String?, activeSince: Date?, issues: [RecipeBuildIssue]) {
        self.key = key
        self.name = name
        self.active = active
        self.activeSince = activeSince
        self.issues = issues
    }

    enum CodingKeys: String, CodingKey {
        case key = "clave", name = "nombre", active = "activa", activeSince = "activaDesde", issues = "errores"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(active, forKey: .active)
        try container.encode(activeSince, forKey: .activeSince)
        try container.encode(issues, forKey: .issues)
    }
}

public func nextInstalled(
    key: String, previous: InstalledRecipe?, outcome: RecipeOutcome, now: Date
) -> (installed: InstalledRecipe?, status: RecipeStatus) {
    switch outcome {
    case .valid(let name, let source, let fingerprint):
        let installed = previous?.fingerprint == fingerprint
            ? previous
            : InstalledRecipe(key: key, name: name, source: source, fingerprint: fingerprint, installedAt: now)
        return (installed, RecipeStatus(
            key: key, name: installed?.name, active: installed?.fingerprint, activeSince: installed?.installedAt,
            issues: []))
    case .failed(let issues):
        return (previous, RecipeStatus(
            key: key, name: previous?.name, active: previous?.fingerprint, activeSince: previous?.installedAt,
            issues: issues))
    }
}

public struct RecipeBuildReport: Sendable, Equatable, Codable {
    public let builtAt: Date
    public let recipes: [RecipeStatus]

    public init(builtAt: Date, recipes: [RecipeStatus]) {
        self.builtAt = builtAt
        self.recipes = recipes
    }

    enum CodingKeys: String, CodingKey {
        case builtAt = "compiladoEn", recipes = "recetas"
    }
}

public func recipeBuildReportJSON(_ report: RecipeBuildReport) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(report), as: UTF8.self) + "\n"
}
