import Foundation
import Synchronization
import EscribaCore

final class RecipeSession: Sendable {
    private struct State {
        var take: Take?
        var language: String?
        var output: URL?
        var steps: [RecipeStep] = []
        var logs: [RecipeLogLine] = []
        var recipes: [String] = []
        var savedData: DataValue?
        var savedSchema: DataValue?
    }

    private let recording: Recording
    private let heard: Recording
    private let capabilities: Capabilities
    private let save: Sink
    private let recipe: Recipe
    private let target: RecipeTarget
    private let dryRun: Bool
    private let startedAt = Date()
    private let clock = ContinuousClock.now
    private let state = Mutex(State())

    private var publishers: [String: Sink] { recipe.publishers }
    private var catalog: RecipeCatalog { recipe.catalog }

    init(
        recording: Recording, audio: URL? = nil, capabilities: Capabilities, save: @escaping Sink, recipe: Recipe,
        target: RecipeTarget, dryRun: Bool = false
    ) {
        self.dryRun = dryRun
        self.recording = recording
        heard = audio.map { Recording(url: $0, startedAt: recording.startedAt, key: recording.key) } ?? recording
        self.capabilities = capabilities
        self.save = save
        self.recipe = recipe
        self.target = target
        state.withLock { $0.recipes = [target.key] }
    }

    var bridge: RecipeBridge { bridge(for: target, chain: [target.info]) }

    private func bridge(for target: RecipeTarget, chain: [RecipeInfo]) -> RecipeBridge {
        let origin = chain.count > 1 ? target.name : nil
        return RecipeBridge(
            audio: recipeAudio(recording, origin: catalog.origin(recording)),
            parameters: target.parameters,
            stts: catalog.stts,
            llms: catalog.llms,
            connectors: catalog.connectors,
            recipes: availableRecipes(),
            transcribe: { try await self.transcribe($0, origin: origin) },
            summarize: { try await self.summarize($0, origin: origin) },
            save: { try await self.saveNote(data: nil, schema: nil, origin: origin) },
            saveData: { try await self.saveNote(data: $0, schema: $1, origin: origin) },
            ask: { try await self.ask($0, schema: $1, origin: origin) },
            publish: { try await self.publish(to: $0, origin: origin) },
            process: { try await self.process($0, chain: chain, origin: origin) },
            log: { self.log($0, $1, origin: origin) })
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
        let seconds = elapsed()
        return state.withLock { state in
            RecipeTrace(
                recipe: target.key, name: target.name, fingerprint: target.package.fingerprint, steps: state.steps,
                logs: state.logs, error: error.map { "\($0)" }, outcome: recipeOutcome(error), recipes: state.recipes,
                startedAt: startedAt, seconds: seconds, data: state.savedData.map { dataText($0) },
                dataSchema: state.savedSchema.map { dataText($0) })
        }
    }

    private func elapsed() -> Double {
        let duration = ContinuousClock.now - clock
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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
        let current = state.withLock { state in
            state.take = sameVersion(state.take, take) ? take.carrying(data: state.take?.data) : take
            state.language = inputs.options.language
            return state.take ?? take
        }
        return note(current)
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

    private func saveNote(data json: String?, schema schemaJSON: String?, origin: String?) async throws {
        let take = try current(for: "guardar")
        let data: DataValue?
        do {
            data = try json.map(noteData) ?? take.data
        } catch {
            record(RecipeStep(capability: "guardar", detail: nil, seconds: 0, error: "\(error)", origin: origin))
            throw error
        }
        let schema = json == nil ? nil : schemaJSON.flatMap { try? parseData($0) }
        if dryRun {
            record(RecipeStep(capability: "guardar", detail: "sin guardar (prueba)", seconds: 0, error: nil, origin: origin))
            remember(saved: data, schema: schema, changed: json != nil, in: take, output: recording.url)
            return
        }
        let output = try await step("guardar", origin: origin) {
            if json != nil { try await capabilities.keep(data, schema: schema, of: recording, in: take) }
            return try await save(delivery(take))
        }
        remember(saved: data, schema: schema, changed: json != nil, in: take, output: output)
    }

    private func remember(saved data: DataValue?, schema: DataValue?, changed: Bool, in take: Take, output: URL) {
        state.withLock { state in
            state.output = output
            state.take = (state.take ?? take).carrying(data: data)
            state.savedData = data
            if changed { state.savedSchema = schema }
        }
    }

    private func ask(_ question: RecipeQuestion, schema json: String?, origin: String?) async throws -> String {
        let schema: AnswerSchema?
        let asker: Asker
        do {
            schema = try json.map { text in try answerSchema(from: try parseData(text)) }
            asker = try catalog.asker(recording, question.llm)
        } catch {
            record(RecipeStep(capability: "preguntar", detail: question.llm, seconds: 0, error: "\(error)", origin: origin))
            throw error
        }
        let request = AnswerRequest(instructions: question.instructions, input: question.input, schema: schema)
        let fingerprint = answerFingerprint(
            model: asker.name, instructions: question.instructions, input: question.input, schema: json)
        let version = state.withLock { $0.take?.version }
        let started = Date()
        do {
            let (answer, remembered) = try await capabilities.ask(
                recording, version: version, asker: asker, request: request, fingerprint: fingerprint)
            record(RecipeStep(
                capability: "preguntar", detail: remembered ? "\(asker.name) · recordado" : asker.name,
                seconds: Date().timeIntervalSince(started), error: nil, origin: origin))
            return dataText(answer)
        } catch {
            record(RecipeStep(
                capability: "preguntar", detail: asker.name, seconds: Date().timeIntervalSince(started),
                error: "\(error)", origin: origin))
            throw error
        }
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
        if dryRun {
            record(RecipeStep(
                capability: "publicar", detail: "\(connector.name) · sin publicar (prueba)", seconds: 0, error: nil,
                origin: origin))
            return
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
        state.withLock { state in
            if !state.recipes.contains(next.key) { state.recipes.append(next.key) }
        }
        try await step("receta", detail: next.name, origin: origin) {
            try await recipe.runtime.run(next.package, bridge(for: next, chain: chain + [next.info]))
        }
    }

    private func log(_ level: RecipeLogLevel, _ text: String, origin: String?) {
        let line = "\(recording.key) [receta] \(origin.map { "\($0): " } ?? "")\(text)"
        switch level {
        case .error: Log.error(line)
        case .warn: Log.info("aviso: \(line)")
        case .info: Log.info(line)
        case .debug: Log.debug(line)
        }
        let entry = RecipeLogLine(level: level, text: text, origin: origin, seconds: elapsed())
        state.withLock { $0.logs.append(entry) }
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
        RecipeNote(
            key: recording.key, version: take.version, transcript: take.transcript, digest: take.digest, data: take.data)
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

private func recipeOutcome(_ error: (any Error)?) -> RecipeRunOutcome {
    guard let error else { return .ok }
    if let transcription = error as? TranscriptionError, transcription.isBackendUnavailable { return .waiting }
    return .failed
}

private func sameVersion(_ previous: Take?, _ next: Take) -> Bool {
    guard let version = next.version else { return false }
    return previous?.version == version
}
