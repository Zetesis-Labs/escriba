import Foundation

public struct RecipeStep: Sendable, Equatable, Codable {
    public let capability: String
    public let detail: String?
    public let seconds: Double
    public let error: String?
    public let origin: String?

    public init(capability: String, detail: String?, seconds: Double, error: String?, origin: String? = nil) {
        self.capability = capability
        self.detail = detail
        self.seconds = seconds
        self.error = error
        self.origin = origin
    }
}

extension RecipeStep {
    public var title: String {
        let base = [capability, detail].compactMap { $0 }.joined(separator: " · ")
        return origin.map { "\($0) › \(base)" } ?? base
    }
}

extension RecipeTrace {
    public var headline: String {
        "Receta «\(name ?? recipe)» · \(fingerprint.prefix(7))"
    }
}

public enum RecipeLogLevel: String, Sendable, Equatable, Codable {
    case debug
    case info
    case warn
    case error
}

public struct RecipeLogLine: Sendable, Equatable, Codable {
    public let level: RecipeLogLevel
    public let text: String
    public let origin: String?
    public let seconds: Double

    public init(level: RecipeLogLevel, text: String, origin: String?, seconds: Double) {
        self.level = level
        self.text = text
        self.origin = origin
        self.seconds = seconds
    }
}

public enum RecipeRunOutcome: String, Sendable, Equatable, Codable {
    case ok
    case failed
    case waiting
}

public enum RecipeRunTrigger: String, Sendable, Equatable, Codable {
    case pipeline
    case reprocess
    case test
}

public struct RecipeTrace: Sendable, Equatable, Codable {
    public let recipe: String
    public let name: String?
    public let fingerprint: String
    public let steps: [RecipeStep]
    public let logs: [RecipeLogLine]
    public let error: String?
    public let outcome: RecipeRunOutcome
    public let recipes: [String]
    public let startedAt: Date?
    public let seconds: Double?
    public let data: String?
    public let dataSchema: String?

    public init(
        recipe: String, name: String? = nil, fingerprint: String, steps: [RecipeStep], logs: [RecipeLogLine],
        error: String?, outcome: RecipeRunOutcome? = nil, recipes: [String]? = nil, startedAt: Date? = nil,
        seconds: Double? = nil, data: String? = nil, dataSchema: String? = nil
    ) {
        self.recipe = recipe
        self.name = name
        self.fingerprint = fingerprint
        self.steps = steps
        self.logs = logs
        self.error = error
        self.outcome = outcome ?? (error == nil ? .ok : .failed)
        self.recipes = recipes ?? [recipe]
        self.startedAt = startedAt
        self.seconds = seconds
        self.data = data
        self.dataSchema = dataSchema
    }

    private enum CodingKeys: String, CodingKey {
        case recipe, name, fingerprint, steps, logs, error, outcome, recipes, startedAt, seconds, data, dataSchema
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let logs: [RecipeLogLine]
        if let lines = try? container.decode([RecipeLogLine].self, forKey: .logs) {
            logs = lines
        } else {
            logs = try (container.decodeIfPresent([String].self, forKey: .logs) ?? []).map {
                RecipeLogLine(level: .info, text: $0, origin: nil, seconds: 0)
            }
        }
        self.init(
            recipe: try container.decode(String.self, forKey: .recipe),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            fingerprint: try container.decode(String.self, forKey: .fingerprint),
            steps: try container.decode([RecipeStep].self, forKey: .steps),
            logs: logs,
            error: try container.decodeIfPresent(String.self, forKey: .error),
            outcome: try container.decodeIfPresent(RecipeRunOutcome.self, forKey: .outcome),
            recipes: try container.decodeIfPresent([String].self, forKey: .recipes),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            seconds: try container.decodeIfPresent(Double.self, forKey: .seconds),
            data: try container.decodeIfPresent(String.self, forKey: .data),
            dataSchema: try container.decodeIfPresent(String.self, forKey: .dataSchema))
    }
}
