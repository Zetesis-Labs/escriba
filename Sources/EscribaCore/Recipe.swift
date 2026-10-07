import Foundation

public struct RecipeAudio: Sendable, Equatable, Encodable {
    public let key: String
    public let name: String
    public let startedAt: Date

    public init(key: String, name: String, startedAt: Date) {
        self.key = key
        self.name = name
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case key = "clave"
        case name = "nombre"
        case startedAt = "fecha"
    }
}

public func recipeAudio(_ recording: Recording) -> RecipeAudio {
    RecipeAudio(
        key: recording.key,
        name: recording.url.deletingPathExtension().lastPathComponent,
        startedAt: recording.startedAt)
}

public struct RecipeNote: Sendable, Equatable, Encodable {
    public let key: String
    public let version: Int64?
    public let transcript: Transcript
    public let digest: Digest?

    public init(key: String, version: Int64?, transcript: Transcript, digest: Digest?) {
        self.key = key
        self.version = version
        self.transcript = transcript
        self.digest = digest
    }

    enum CodingKeys: String, CodingKey {
        case key = "clave", version, text = "texto", speakers = "hablantes", segments = "segmentos"
        case digest = "resumen"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(version, forKey: .version)
        try container.encode(transcript.text, forKey: .text)
        try container.encode(transcript.speakers, forKey: .speakers)
        try container.encode(transcript.segments.map(RecipeSegment.init), forKey: .segments)
        try container.encode(digest.map(RecipeDigest.init), forKey: .digest)
    }
}

private struct RecipeSegment: Encodable {
    let segment: TranscriptSegment

    enum CodingKeys: String, CodingKey {
        case start = "inicio", end = "fin", speaker = "hablante", text = "texto", words = "palabras"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segment.start, forKey: .start)
        try container.encode(segment.end, forKey: .end)
        try container.encode(segment.speaker, forKey: .speaker)
        try container.encode(segment.text, forKey: .text)
        try container.encode(segment.words.map(RecipeWord.init), forKey: .words)
    }
}

private struct RecipeWord: Encodable {
    let word: TranscriptWord

    enum CodingKeys: String, CodingKey {
        case start = "inicio", end = "fin", text = "texto"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(word.start, forKey: .start)
        try container.encode(word.end, forKey: .end)
        try container.encode(word.text, forKey: .text)
    }
}

private struct RecipeDigest: Encodable {
    let digest: Digest

    enum CodingKeys: String, CodingKey {
        case title = "titulo", summary = "texto", tags = "etiquetas"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(digest.title, forKey: .title)
        try container.encode(digest.summary, forKey: .summary)
        try container.encode(digest.tags, forKey: .tags)
    }
}

public func recipeJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

public struct RecipeStep: Sendable, Equatable, Codable {
    public let capability: String
    public let detail: String?
    public let seconds: Double
    public let error: String?

    public init(capability: String, detail: String?, seconds: Double, error: String?) {
        self.capability = capability
        self.detail = detail
        self.seconds = seconds
        self.error = error
    }
}

extension RecipeStep {
    public var title: String {
        [capability, detail].compactMap { $0 }.joined(separator: " · ")
    }
}

extension RecipeTrace {
    public var headline: String {
        "Receta «\(recipe)» · \(fingerprint.prefix(7))"
    }
}

public struct RecipeTrace: Sendable, Equatable, Codable {
    public let recipe: String
    public let fingerprint: String
    public let steps: [RecipeStep]
    public let logs: [String]
    public let error: String?

    public init(recipe: String, fingerprint: String, steps: [RecipeStep], logs: [String], error: String?) {
        self.recipe = recipe
        self.fingerprint = fingerprint
        self.steps = steps
        self.logs = logs
        self.error = error
    }
}
