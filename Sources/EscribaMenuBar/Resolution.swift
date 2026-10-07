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
    return base.prompted(resolver.prompt)
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

nonisolated func routedTranscriber(
    _ routing: ResolverRouting, options: TranscriptionOptions, engine: WhisperKitEngine
) -> TranscriptionBackend {
    TranscriptionBackend(
        name: "según la grabación",
        transcribe: { source async throws(TranscriptionError) in
            let stt = routing.resolver(.stt, forSource: source.path(percentEncoded: false))
            return try await transcriber(for: stt, options: options, engine: engine).transcribe(source)
        },
        route: { source in
            routing.resolver(.stt, forSource: source.path(percentEncoded: false)).id.uuidString
        },
        inputs: { source in
            let stt = routing.resolver(.stt, forSource: source.path(percentEncoded: false))
            return TranscriptionInputs(backend: backendLabel(stt), options: options)
        })
}

nonisolated func recipeCatalog(
    routing: ResolverRouting, stts: ResolverSet, llms: ResolverSet, connectors: [RecipeConnector],
    folderOptions: TranscriptionOptions, language: String?, engine: WhisperKitEngine
) -> RecipeCatalog {
    RecipeCatalog(
        stts: recipeResolvers(stts),
        llms: recipeResolvers(llms),
        connectors: connectors,
        transcriber: { recording, request in
            let resolver = try request.stt.map { try lookupResolver($0, in: stts) }
                ?? routing.resolver(.stt, forSource: recording.url.path(percentEncoded: false))
            let options = request.options(over: folderOptions)
            if let problem = transcriptionProblem(isLocal: resolver.kind == .local, options: options) {
                throw RecipeError.failed(problem)
            }
            let chosen = transcriber(for: resolver, options: options, engine: engine)
            return TranscriptionBackend(
                name: chosen.name, transcribe: chosen.transcribe,
                route: { _ in resolver.id.uuidString },
                inputs: { _ in TranscriptionInputs(backend: backendLabel(resolver), options: options) })
        },
        summarizer: { recording, request in
            let resolver = try request.llm.map { try lookupResolver($0, in: llms) }
                ?? routing.resolver(.llm, forSource: recording.url.path(percentEncoded: false))
            let chosen = summarizer(for: resolver).prompted(request.prompt ?? resolver.prompt)
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
            isFavorite: resolver.id == set.favorite,
            model: remote && !resolver.model.isEmpty ? resolver.model : nil,
            baseURL: remote && !resolver.baseURL.isEmpty ? resolver.baseURL : nil,
            prompt: set.role == .llm ? resolver.prompt : nil)
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
        query, in: set.resolvers, kind: set.role == .stt ? "STT" : "LLM",
        key: { $0.recipeKey(role: set.role) }, name: \.name)
}

nonisolated func routedEnricher(_ routing: ResolverRouting, language: String?) -> Enricher {
    { recording, transcript in
        let llm = routing.resolver(.llm, forSource: recording.url.path(percentEncoded: false))
        return await enricher(summarizer(for: llm), language: language)(recording, transcript)
    }
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
