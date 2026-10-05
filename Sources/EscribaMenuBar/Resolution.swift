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
        })
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
