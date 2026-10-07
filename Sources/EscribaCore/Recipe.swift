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

public struct RecipeResolver: Sendable, Equatable, Encodable {
    public let key: String
    public let name: String
    public let isLocal: Bool
    public let model: String?
    public let baseURL: String?

    public init(
        key: String, name: String, isLocal: Bool, model: String? = nil, baseURL: String? = nil
    ) {
        self.key = key
        self.name = name
        self.isLocal = isLocal
        self.model = model
        self.baseURL = baseURL
    }

    enum CodingKeys: String, CodingKey {
        case key = "clave", name = "nombre", isLocal = "local", model = "modelo"
        case baseURL = "url"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(isLocal, forKey: .isLocal)
        try container.encode(model, forKey: .model)
        try container.encode(baseURL, forKey: .baseURL)
    }
}

public struct RecipeConnector: Sendable, Equatable, Encodable {
    public struct NotionBase: Sendable, Equatable, Encodable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case id, name = "nombre"
        }
    }

    public let key: String
    public let name: String
    public let kind: String
    public let isActive: Bool
    public let notionBase: NotionBase?
    public let folder: String?

    public init(
        key: String, name: String, kind: String, isActive: Bool = true, notionBase: NotionBase? = nil,
        folder: String? = nil
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.isActive = isActive
        self.notionBase = notionBase
        self.folder = folder
    }

    enum CodingKeys: String, CodingKey {
        case key = "clave", name = "nombre", kind = "tipo", isActive = "activo", notionBase = "base"
        case folder = "carpeta"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(notionBase, forKey: .notionBase)
        try container.encode(folder, forKey: .folder)
    }
}

public enum RecipeLookupError: Error, Equatable, CustomStringConvertible {
    case missing(kind: String, query: String)
    case ambiguous(kind: String, query: String)

    public var description: String {
        switch self {
        case .missing(let kind, let query): "no hay ningún \(kind) «\(query)»"
        case .ambiguous(_, let query): "el nombre «\(query)» lo llevan varios: usa su clave"
        }
    }
}

public func recipeLookup<Item>(
    _ query: String, in items: [Item], kind: String, key: (Item) -> String, name: (Item) -> String
) throws(RecipeLookupError) -> Item {
    if let exact = items.first(where: { key($0) == query }) { return exact }
    let named = items.filter { name($0).localizedCaseInsensitiveCompare(query) == .orderedSame }
    guard named.count < 2 else { throw .ambiguous(kind: kind, query: query) }
    guard let match = named.first else { throw .missing(kind: kind, query: query) }
    return match
}

public struct RecipeTranscription: Sendable, Equatable, Decodable {
    public enum Language: Sendable, Equatable {
        case folder
        case automatic
        case code(String)
    }

    public struct Speakers: Sendable, Equatable, Decodable {
        public let detect: Bool
        public let count: Int?

        public init(detect: Bool, count: Int? = nil) {
            self.detect = detect
            self.count = count
        }

        enum CodingKeys: String, CodingKey {
            case detect = "detectar", count = "cuantos"
        }
    }

    public let stt: String?
    public let language: Language
    public let speakers: Speakers?

    public init(stt: String? = nil, language: Language = .folder, speakers: Speakers? = nil) {
        self.stt = stt
        self.language = language
        self.speakers = speakers
    }

    enum CodingKeys: String, CodingKey {
        case stt, language = "idioma", speakers = "hablantes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stt = try container.decodeIfPresent(String.self, forKey: .stt)
        speakers = try container.decodeIfPresent(Speakers.self, forKey: .speakers)
        if !container.contains(.language) {
            language = .folder
        } else if try container.decodeNil(forKey: .language) {
            language = .automatic
        } else {
            language = .code(try container.decode(String.self, forKey: .language))
        }
    }

    public var isDefault: Bool { stt == nil && language == .folder && speakers == nil }

    public func options(over folder: TranscriptionOptions) -> TranscriptionOptions {
        let language: String? = switch self.language {
        case .folder: folder.language
        case .automatic: nil
        case .code(let code): code
        }
        guard let speakers else {
            return TranscriptionOptions(language: language, diarize: folder.diarize, speakerCount: folder.speakerCount)
        }
        return TranscriptionOptions(language: language, diarize: speakers.detect, speakerCount: speakers.count)
    }
}

public struct RecipeSummaryRequest: Sendable, Equatable, Decodable {
    public let llm: String?
    public let prompt: String?

    public init(llm: String? = nil, prompt: String? = nil) {
        self.llm = llm
        self.prompt = prompt
    }

    public var isDefault: Bool { llm == nil && prompt == nil }
}

public func transcriptionProblem(isLocal: Bool, options: TranscriptionOptions) -> String? {
    guard !isLocal, options.diarize else { return nil }
    return "un STT remoto no detecta hablantes: usa Whisper o pide hablantes: { detectar: false }"
}
