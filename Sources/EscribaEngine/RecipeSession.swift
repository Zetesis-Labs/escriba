import Foundation
import Synchronization
import EscribaCore

final class RecipeSession: Sendable {
    private struct State {
        var take: Take?
        var language: String?
        var output: URL?
        var steps: [RecipeStep] = []
        var logs: [String] = []
    }

    private let recording: Recording
    private let heard: Recording
    private let capabilities: Capabilities
    private let save: Sink
    private let recipe: Recipe
    private let target: RecipeTarget
    private let state = Mutex(State())

    private var publishers: [String: Sink] { recipe.publishers }
    private var catalog: RecipeCatalog { recipe.catalog }

    init(
        recording: Recording, audio: URL? = nil, capabilities: Capabilities, save: @escaping Sink, recipe: Recipe,
        target: RecipeTarget
    ) {
        self.recording = recording
        heard = audio.map { Recording(url: $0, startedAt: recording.startedAt, key: recording.key) } ?? recording
        self.capabilities = capabilities
        self.save = save
        self.recipe = recipe
        self.target = target
    }

    var bridge: RecipeBridge { bridge(for: target, chain: [target.info]) }

    private func bridge(for target: RecipeTarget, chain: [RecipeInfo]) -> RecipeBridge {
        let origin = chain.count > 1 ? target.name : nil
        return RecipeBridge(
            audio: recipeAudio(recording),
            parameters: target.parameters,
            stts: catalog.stts,
            llms: catalog.llms,
            connectors: catalog.connectors,
            recipes: availableRecipes(),
            transcribe: { try await self.transcribe($0, origin: origin) },
            summarize: { try await self.summarize($0, origin: origin) },
            save: { try await self.saveNote(origin: origin) },
            publish: { try await self.publish(to: $0, origin: origin) },
            process: { try await self.process($0, chain: chain, origin: origin) },
            log: { self.log($0, origin: origin) })
    }

    private func availableRecipes() -> [RecipeInfo] {
        do {
            return try recipe.shelf.recipes()
        } catch {
            Log.error("\(recording.key) [receta] no se pudo leer la lista de recetas: \(error)")
            return []
        }
    }

    var delivered: (transcript: Transcript, output: URL)? {
        state.withLock { state in
            guard let take = state.take, let output = state.output else { return nil }
            return (take.transcript, output)
        }
    }

    func trace(error: (any Error)?) -> RecipeTrace {
        state.withLock { state in
            RecipeTrace(
                recipe: target.key, name: target.name, fingerprint: target.package.fingerprint, steps: state.steps,
                logs: state.logs, error: error.map { "\($0)" })
        }
    }

    private func transcribe(_ request: RecipeTranscription, origin: String?) async throws -> RecipeNote {
        let chosen: TranscriptionBackend?
        do {
            chosen = request.isDefault ? nil : try catalog.transcriber(heard, request)
        } catch {
            record(RecipeStep(
                capability: "transcribir", detail: request.stt, seconds: 0, error: "\(error)", origin: origin))
            throw error
        }
        let inputs = (chosen ?? capabilities.backend).inputs(heard.url)
        let take = try await step(
            "transcribir", detail: "\(inputs.backend) · \(inputs.options.label)", origin: origin
        ) {
            try await capabilities.transcribe(heard, with: chosen)
        }
        state.withLock { state in
            state.take = take
            state.language = inputs.options.language
        }
        return note(take)
    }

    private func summarize(_ request: RecipeSummaryRequest, origin: String?) async throws -> RecipeNote {
        let transcribed = try current(for: "resumir")
        let chosen: ChosenSummarizer?
        do {
            chosen = request.isDefault
                ? nil : try catalog.summarizer(recording, request, state.withLock { $0.language })
        } catch {
            record(RecipeStep(capability: "resumir", detail: request.llm, seconds: 0, error: "\(error)", origin: origin))
            throw error
        }
        guard chosen != nil || capabilities.enrich != nil else {
            record(RecipeStep(capability: "resumir", detail: "sin LLM", seconds: 0, error: nil, origin: origin))
            return note(transcribed)
        }
        let started = Date()
        let summarized = try await capabilities.summarize(recording, transcribed, with: chosen?.enrich)
        record(RecipeStep(
            capability: "resumir",
            detail: summaryDetail(label: chosen?.label, remembered: transcribed.digest != nil, got: summarized.digest != nil),
            seconds: Date().timeIntervalSince(started), error: nil, origin: origin))
        state.withLock { $0.take = summarized }
        return note(summarized)
    }

    private func saveNote(origin: String?) async throws {
        let take = try current(for: "guardar")
        let output = try await step("guardar", origin: origin) { try await save(delivery(take)) }
        state.withLock { $0.output = output }
    }

    private func publish(to target: String, origin: String?) async throws {
        let take = try current(for: "publicar")
        let publisher: Sink
        let connector: RecipeConnector
        do {
            connector = try recipeLookup(target, in: catalog.connectors, kind: .connector, key: \.key, name: \.name)
            guard connector.isActive, let found = publishers[connector.key] else {
                throw RecipeError.inactiveConnector(connector.name)
            }
            publisher = found
        } catch {
            record(RecipeStep(capability: "publicar", detail: target, seconds: 0, error: "\(error)", origin: origin))
            throw error
        }
        _ = try await step("publicar", detail: connector.name, origin: origin) {
            try await publisher(delivery(take))
        }
    }

    private func process(_ query: String, chain: [RecipeInfo], origin: String?) async throws {
        let next: RecipeTarget
        do {
            next = try recipe.shelf.target(query)
            if let problem = recipeCallProblem(chain: chain, next: next.info) { throw problem }
        } catch {
            record(RecipeStep(capability: "receta", detail: query, seconds: 0, error: "\(error)", origin: origin))
            throw error
        }
        try await step("receta", detail: next.name, origin: origin) {
            try await recipe.runtime.run(next.package, bridge(for: next, chain: chain + [next.info]))
        }
    }

    private func log(_ text: String, origin: String?) {
        let line = origin.map { "\($0): \(text)" } ?? text
        Log.info("\(recording.key) [receta] \(line)")
        state.withLock { $0.logs.append(line) }
    }

    private func current(for capability: String) throws -> Take {
        guard let take = state.withLock({ $0.take }) else { throw RecipeError.notTranscribed(capability) }
        return take
    }

    private func step<T>(
        _ capability: String, detail: String? = nil, origin: String?, _ body: () async throws -> T
    ) async throws -> T {
        let started = Date()
        do {
            let result = try await body()
            record(RecipeStep(
                capability: capability, detail: detail, seconds: Date().timeIntervalSince(started), error: nil,
                origin: origin))
            return result
        } catch {
            record(RecipeStep(
                capability: capability, detail: detail, seconds: Date().timeIntervalSince(started),
                error: "\(error)", origin: origin))
            throw error
        }
    }

    private func record(_ step: RecipeStep) {
        state.withLock { $0.steps.append(step) }
    }

    private func note(_ take: Take) -> RecipeNote {
        RecipeNote(key: recording.key, version: take.version, transcript: take.transcript, digest: take.digest)
    }

    private func delivery(_ take: Take) -> Note {
        Note(recording: recording, transcript: take.transcript, digest: take.digest)
    }
}

private func summaryDetail(label: String?, remembered: Bool, got: Bool) -> String? {
    let outcome = remembered ? "recordado" : got ? nil : "sin resumen"
    let parts = [label, outcome].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
