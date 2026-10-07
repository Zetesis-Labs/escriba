import Foundation
import EscribaCore
import EscribaEngine
import EscribaIntelligence
import EscribaModel
import EscribaOpenAI
import EscribaWhisper

nonisolated private let remoteTransport = urlSessionRemoteTransport()

nonisolated func openAIEndpoint(
    _ resolver: Resolver, apiKey: (@Sendable () -> String?)? = nil
) -> OpenAIEndpoint {
    let id = resolver.id
    return OpenAIEndpoint(
        baseURL: resolver.baseURL, model: resolver.model,
        apiKey: apiKey ?? { resolverTokenStore(id).read() })
}

nonisolated func summarizer(
    for resolver: Resolver, apiKey: (@Sendable () -> String?)? = nil
) -> Summarizer {
    let base = switch resolver.kind {
    case .local: AppleIntelligence.summarizer()
    case .remote:
        openAISummarizer(
            name: resolver.name, endpoint: openAIEndpoint(resolver, apiKey: apiKey), transport: remoteTransport)
    }
    return base
}

nonisolated func recipeResolver(_ set: ResolverSet, key: String) -> Resolver {
    set.resolvers.first { $0.recipeKey(role: set.role) == key } ?? set.local
}

nonisolated func recipeTranscriber(
    _ stt: Resolver, options: TranscriptionOptions, engine: WhisperKitEngine
) -> TranscriptionBackend {
    let chosen = transcriber(for: stt, options: options, engine: engine)
    return TranscriptionBackend(
        name: chosen.name, transcribe: chosen.transcribe,
        route: { _ in stt.id.uuidString },
        inputs: { _ in TranscriptionInputs(backend: backendLabel(stt), options: options) })
}

nonisolated func transcriber(
    for resolver: Resolver, options: TranscriptionOptions, engine: WhisperKitEngine
) -> TranscriptionBackend {
    switch resolver.kind {
    case .local:
        engine.backend(options: options)
    case .remote:
        openAITranscriber(
            name: resolver.name, endpoint: openAIEndpoint(resolver), language: options.language,
            transport: remoteTransport)
    }
}

nonisolated func recipeCatalog(
    stts: ResolverSet, llms: ResolverSet, connectors: [RecipeConnector], unchosen: TranscriptionOptions,
    engine: WhisperKitEngine
) -> RecipeCatalog {
    RecipeCatalog(
        stts: recipeResolvers(stts),
        llms: recipeResolvers(llms),
        connectors: connectors,
        transcriber: { _, request in
            let resolver = try request.stt.map { try lookupResolver($0, in: stts) } ?? stts.local
            let options = request.options(over: unchosen)
            if let problem = transcriptionProblem(isLocal: resolver.kind == .local, options: options) {
                throw RecipeError.failed(problem)
            }
            let chosen = transcriber(for: resolver, options: options, engine: engine)
            return TranscriptionBackend(
                name: chosen.name, transcribe: chosen.transcribe,
                route: { _ in resolver.id.uuidString },
                inputs: { _ in TranscriptionInputs(backend: backendLabel(resolver), options: options) })
        },
        summarizer: { _, request, language in
            let resolver = try request.llm.map { try lookupResolver($0, in: llms) } ?? llms.local
            let chosen = summarizer(for: resolver).prompted(request.prompt)
            let label = [resolver.name, request.prompt == nil ? nil : "prompt propio"]
                .compactMap { $0 }.joined(separator: " · ")
            return ChosenSummarizer(label: label, enrich: enricher(chosen, language: language))
        })
}

nonisolated private func recipeResolvers(_ set: ResolverSet) -> [RecipeResolver] {
    set.resolvers.map { resolver in
        let remote = resolver.kind == .remote
        return RecipeResolver(
            key: resolver.recipeKey(role: set.role), name: resolver.name, isLocal: !remote,
            model: remote && !resolver.model.isEmpty ? resolver.model : nil,
            baseURL: remote && !resolver.baseURL.isEmpty ? resolver.baseURL : nil)
    }
}

func recipeConnector(_ connector: Connector, isActive: Bool) -> RecipeConnector {
    RecipeConnector(
        key: connector.key, name: connector.name, kind: connector.kind.rawValue, isActive: isActive,
        notionBase: connector.notion.map { RecipeConnector.NotionBase(id: $0.source.id, name: $0.source.databaseTitle) },
        folder: connector.okf.map(\.folder))
}

nonisolated private func lookupResolver(_ query: String, in set: ResolverSet) throws -> Resolver {
    try recipeLookup(
        query, in: set.resolvers, kind: set.role == .stt ? .stt : .llm,
        key: { $0.recipeKey(role: set.role) }, name: \.name)
}

nonisolated func backendLabel(_ resolver: Resolver) -> String {
    switch resolver.kind {
    case .local: WhisperKitBackend.name
    case .remote: [resolver.name, resolver.model].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

nonisolated func localResolverProblem(_ role: ResolverRole) -> String? {
    switch role {
    case .stt:
        WhisperKitBackend.installedModelFolder() == nil
            ? "el modelo de Whisper no está descargado; descárgalo aquí abajo" : nil
    case .llm:
        AppleIntelligence.availability().problem
    }
}

nonisolated func resolverServices() -> ResolverServices {
    ResolverServices(
        models: { resolver, key in
            try await remoteModels(endpoint: openAIEndpoint(resolver, apiKey: { key }), transport: remoteTransport)
        },
        summarize: { resolver, key, text in
            try await summarizer(for: resolver, apiKey: { key }).digest(of: text, language: nil)
        },
        transcribe: { resolver, key in
            let backend = openAITranscriber(
                name: resolver.name, endpoint: openAIEndpoint(resolver, apiKey: { key }), language: nil,
                transport: remoteTransport, readAudio: { _ in silentWAV() })
            return try await backend.transcribe(URL(fileURLWithPath: "prueba.wav")).text
        },
        localProblem: localResolverProblem)
}
