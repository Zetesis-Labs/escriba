import Foundation
import EscribaCore

public struct RecipePackage: Sendable, Equatable {
    public let key: String
    public let source: String
    public let fingerprint: String

    public init(key: String, source: String, fingerprint: String) {
        self.key = key
        self.source = source
        self.fingerprint = fingerprint
    }
}

public struct ChosenSummarizer: Sendable {
    public let label: String
    public let enrich: Enricher

    public init(label: String, enrich: @escaping Enricher) {
        self.label = label
        self.enrich = enrich
    }
}

public struct RecipeCatalog: Sendable {
    public var stts: [RecipeResolver]
    public var llms: [RecipeResolver]
    public var connectors: [RecipeConnector]
    public var transcriber: @Sendable (Recording, RecipeTranscription) throws -> TranscriptionBackend
    public var summarizer: @Sendable (Recording, RecipeSummaryRequest) throws -> ChosenSummarizer

    public init(
        stts: [RecipeResolver] = [],
        llms: [RecipeResolver] = [],
        connectors: [RecipeConnector] = [],
        transcriber: @escaping @Sendable (Recording, RecipeTranscription) throws -> TranscriptionBackend = { _, _ in
            throw RecipeError.unavailable("aquí no se puede elegir con qué transcribir")
        },
        summarizer: @escaping @Sendable (Recording, RecipeSummaryRequest) throws -> ChosenSummarizer = { _, _ in
            throw RecipeError.unavailable("aquí no se puede elegir con qué resumir")
        }
    ) {
        self.stts = stts
        self.llms = llms
        self.connectors = connectors
        self.transcriber = transcriber
        self.summarizer = summarizer
    }
}

public struct RecipeBridge: Sendable {
    public var audio: RecipeAudio
    public var stts: [RecipeResolver]
    public var llms: [RecipeResolver]
    public var connectors: [RecipeConnector]
    public var transcribe: @Sendable (RecipeTranscription) async throws -> RecipeNote
    public var summarize: @Sendable (RecipeSummaryRequest) async throws -> RecipeNote
    public var save: @Sendable () async throws -> Void
    public var publish: @Sendable (String) async throws -> Void
    public var log: @Sendable (String) -> Void

    public init(
        audio: RecipeAudio,
        stts: [RecipeResolver] = [],
        llms: [RecipeResolver] = [],
        connectors: [RecipeConnector],
        transcribe: @escaping @Sendable (RecipeTranscription) async throws -> RecipeNote,
        summarize: @escaping @Sendable (RecipeSummaryRequest) async throws -> RecipeNote,
        save: @escaping @Sendable () async throws -> Void,
        publish: @escaping @Sendable (String) async throws -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.audio = audio
        self.stts = stts
        self.llms = llms
        self.connectors = connectors
        self.transcribe = transcribe
        self.summarize = summarize
        self.save = save
        self.publish = publish
        self.log = log
    }
}

public struct RecipeRuntime: Sendable {
    public let name: String
    public let run: @Sendable (RecipePackage, RecipeBridge) async throws -> Void

    public init(name: String, run: @escaping @Sendable (RecipePackage, RecipeBridge) async throws -> Void) {
        self.name = name
        self.run = run
    }
}

public struct Recipe: Sendable {
    public let package: RecipePackage
    public let runtime: RecipeRuntime
    public let publishers: [String: Sink]
    public let catalog: RecipeCatalog

    public init(
        package: RecipePackage, runtime: RecipeRuntime, publishers: [String: Sink],
        catalog: RecipeCatalog = RecipeCatalog()
    ) {
        self.package = package
        self.runtime = runtime
        self.publishers = publishers
        var catalog = catalog
        if catalog.connectors.isEmpty {
            catalog.connectors = publishers.keys.sorted().map { RecipeConnector(key: $0, name: $0, kind: "") }
        }
        self.catalog = catalog
    }
}

public enum RecipeError: Error, Equatable, CustomStringConvertible {
    case failed(String)
    case invalidPackage(String)
    case timedOut(Double)
    case stalled
    case notSaved
    case notTranscribed(String)
    case unknownConnector(String)
    case inactiveConnector(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .failed(let message): "la receta falló: \(message)"
        case .invalidPackage(let message): "la receta no carga: \(message)"
        case .timedOut(let seconds):
            "la receta pasó más de \(seconds == seconds.rounded() ? "\(Int(seconds))" : "\(seconds)") s ejecutando sin esperar a nada"
        case .stalled: "la receta se quedó esperando algo que nunca llega"
        case .notSaved: "la receta terminó sin guardar la nota"
        case .notTranscribed(let capability): "la receta pidió \(capability) antes de transcribir"
        case .unknownConnector(let key): "no hay ningún conector «\(key)»"
        case .inactiveConnector(let name): "el conector «\(name)» está apagado o sin terminar de configurar"
        case .unavailable(let reason): "las recetas no están disponibles: \(reason)"
        }
    }
}
