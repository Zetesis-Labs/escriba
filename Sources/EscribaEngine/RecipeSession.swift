import Foundation
import Synchronization
import EscribaCore

final class RecipeSession: Sendable {
    private struct State {
        var take: Take?
        var output: URL?
        var steps: [RecipeStep] = []
        var logs: [String] = []
    }

    private let recording: Recording
    private let capabilities: Capabilities
    private let save: Sink
    private let publishers: [String: Sink]
    private let state = Mutex(State())

    init(recording: Recording, capabilities: Capabilities, save: @escaping Sink, publishers: [String: Sink]) {
        self.recording = recording
        self.capabilities = capabilities
        self.save = save
        self.publishers = publishers
    }

    var bridge: RecipeBridge {
        RecipeBridge(
            audio: recipeAudio(recording),
            connectors: publishers.keys.sorted(),
            transcribe: { try await self.transcribe() },
            summarize: { try await self.summarize() },
            save: { try await self.saveNote() },
            publish: { try await self.publish(to: $0) },
            log: { self.log($0) })
    }

    var delivered: (transcript: Transcript, output: URL)? {
        state.withLock { state in
            guard let take = state.take, let output = state.output else { return nil }
            return (take.transcript, output)
        }
    }

    func trace(of package: RecipePackage, error: (any Error)?) -> RecipeTrace {
        state.withLock { state in
            RecipeTrace(
                recipe: package.key, fingerprint: package.fingerprint, steps: state.steps,
                logs: state.logs, error: error.map { "\($0)" })
        }
    }

    private func transcribe() async throws -> RecipeNote {
        let take = try await step("transcribir") { try await capabilities.transcribe(recording) }
        state.withLock { $0.take = take }
        return note(take)
    }

    private func summarize() async throws -> RecipeNote {
        let transcribed = try current(for: "resumir")
        guard capabilities.enrich != nil else {
            record(RecipeStep(capability: "resumir", detail: "apagado en Ajustes", seconds: 0, error: nil))
            return note(transcribed)
        }
        let started = Date()
        let summarized = try await capabilities.summarize(recording, transcribed)
        record(RecipeStep(
            capability: "resumir", detail: summarized.digest == nil ? "sin resumen" : nil,
            seconds: Date().timeIntervalSince(started), error: nil))
        state.withLock { $0.take = summarized }
        return note(summarized)
    }

    private func saveNote() async throws {
        let take = try current(for: "guardar")
        let output = try await step("guardar") { try await save(delivery(take)) }
        state.withLock { $0.output = output }
    }

    private func publish(to key: String) async throws {
        let take = try current(for: "publicar")
        guard let publisher = publishers[key] else {
            let error = RecipeError.unknownConnector(key)
            record(RecipeStep(capability: "publicar", detail: key, seconds: 0, error: "\(error)"))
            throw error
        }
        _ = try await step("publicar", detail: key) { try await publisher(delivery(take)) }
    }

    private func log(_ text: String) {
        Log.info("\(recording.key) [receta] \(text)")
        state.withLock { $0.logs.append(text) }
    }

    private func current(for capability: String) throws -> Take {
        guard let take = state.withLock({ $0.take }) else { throw RecipeError.notTranscribed(capability) }
        return take
    }

    private func step<T>(
        _ capability: String, detail: String? = nil, _ body: () async throws -> T
    ) async throws -> T {
        let started = Date()
        do {
            let result = try await body()
            record(RecipeStep(
                capability: capability, detail: detail, seconds: Date().timeIntervalSince(started), error: nil))
            return result
        } catch {
            record(RecipeStep(
                capability: capability, detail: detail, seconds: Date().timeIntervalSince(started),
                error: "\(error)"))
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
