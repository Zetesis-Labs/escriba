import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let paquete = RecipePackage(key: "prueba", source: "", fingerprint: "abc123")

private func runtime(_ body: @escaping @Sendable (RecipeBridge) async throws -> Void) -> RecipeRuntime {
    RecipeRuntime(name: "falso") { _, bridge in try await body(bridge) }
}

private let porDefecto: @Sendable (RecipeBridge) async throws -> Void = { escriba in
    _ = try await escriba.transcribe()
    _ = try await escriba.summarize()
    try await escriba.save()
    for clave in escriba.connectors {
        do {
            try await escriba.publish(clave)
        } catch {
            escriba.log("no se pudo publicar en \(clave): \(error)")
        }
    }
}

private func transcribe(_ steps: Trace<String>) -> TranscriptionBackend {
    backend { _ in
        steps.append("transcribe")
        return Transcript(text: "hola")
    }
}

private func resumidor(_ steps: Trace<String>) -> Enricher {
    { _, _ in
        steps.append("resume")
        return Digest(title: "Hola", summary: "Adiós", tags: [])
    }
}

private func guarda(_ steps: Trace<String>) -> Sink {
    { note in
        steps.append("entrega")
        return URL(fileURLWithPath: "/salida/\(note.recording.key).txt")
    }
}

private func publica(_ steps: Trace<String>, en clave: String, falla: Bool = false) -> Sink {
    { note in
        if falla { throw FakeError.sinkBroken }
        steps.append("publica \(clave)")
        return URL(fileURLWithPath: "/\(clave)/\(note.recording.key)")
    }
}

private func trazas(_ eventos: Trace<PipelineEvent>) -> [RecipeTrace] {
    eventos.values.compactMap { event in
        if case .traced(_, let trace) = event { trace } else { nil }
    }
}

@Suite("Pipeline con receta")
struct RecetaTests {
    @Test("con la receta por defecto la nota pasa por los mismos pasos que sin receta")
    func paridad() async throws {
        let sinReceta = Trace<String>()
        let conReceta = Trace<String>()

        try await Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(sinReceta),
            sink: sinks(primary: guarda(sinReceta), all: [forgiving(publica(sinReceta, en: "notion"))]),
            enrich: resumidor(sinReceta), memory: MemoryNotes(steps: sinReceta).port
        ).runOnce()
        try await Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(conReceta), sink: guarda(conReceta),
            enrich: resumidor(conReceta), memory: MemoryNotes(steps: conReceta).port,
            recipe: Recipe(
                package: paquete, runtime: runtime(porDefecto),
                publishers: ["notion": publica(conReceta, en: "notion")])
        ).runOnce()

        #expect(conReceta.values == sinReceta.values)
        #expect(conReceta.values == [
            "transcribe", "guarda transcripcion", "resume", "guarda resumen v1", "entrega", "publica notion",
        ])
    }

    @Test("con receta se anuncian los mismos eventos que sin ella, mas su traza")
    func eventos() async throws {
        let eventos = Trace<PipelineEvent>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(Trace()), sink: guarda(Trace()),
            recipe: Recipe(package: paquete, runtime: runtime(porDefecto), publishers: [:]),
            onEvent: { eventos.append($0) })

        let outcome = try await pipeline.runOnce()

        #expect(outcome == PassOutcome(processed: 1, deferred: 0))
        #expect(ledger.doneKeys == ["a"])
        #expect(eventos.values.map(label) == ["scanned", "passStarted", "transcribing", "traced", "transcribed"])
    }

    @Test("la traza dice que receta proceso la nota y cada paso que pidio")
    func traza() async throws {
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(Trace()), sink: guarda(Trace()), enrich: resumidor(Trace()),
            recipe: Recipe(
                package: paquete, runtime: runtime(porDefecto),
                publishers: ["notion": publica(Trace(), en: "notion")]),
            onEvent: { eventos.append($0) })

        try await pipeline.runOnce()

        let traza = try #require(trazas(eventos).first)
        #expect(traza.recipe == "prueba")
        #expect(traza.fingerprint == "abc123")
        #expect(traza.steps.map(\.capability) == ["transcribir", "resumir", "guardar", "publicar"])
        #expect(traza.steps.last?.detail == "notion")
        #expect(traza.error == nil)
    }

    @Test("un conector que falla no tumba la nota si la receta lo recoge, y queda en la traza")
    func conectorQueFalla() async throws {
        let eventos = Trace<PipelineEvent>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(Trace()), sink: guarda(Trace()),
            recipe: Recipe(
                package: paquete, runtime: runtime(porDefecto),
                publishers: ["notion": publica(Trace(), en: "notion", falla: true)]),
            onEvent: { eventos.append($0) })

        try await pipeline.runOnce()

        let traza = try #require(trazas(eventos).first)
        #expect(ledger.doneKeys == ["a"])
        #expect(traza.steps.last?.error != nil)
        #expect(traza.logs.first?.contains("no se pudo publicar en notion") == true)
    }

    @Test("con los resumenes apagados, resumir no llama a ningun modelo y la traza lo dice")
    func resumenesApagados() async throws {
        let pasos = Trace<String>()
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(pasos), sink: guarda(pasos),
            recipe: Recipe(package: paquete, runtime: runtime(porDefecto), publishers: [:]),
            onEvent: { eventos.append($0) })

        try await pipeline.runOnce()

        #expect(!pasos.values.contains("resume"))
        #expect(trazas(eventos).first?.steps[1].detail == "apagado en Ajustes")
    }

    @Test("un motor caido que la receta no recoge aplaza sus notas y aparta su ruta, igual que sin receta")
    func motorCaido() async throws {
        let llamadas = Trace<URL>()
        let ledger = MemoryLedger()
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a"), recording("b", minute: 1)]), ledger: ledger.port,
            backend: backend { url throws(TranscriptionError) in
                llamadas.append(url)
                throw .backendUnavailable("apagado")
            },
            sink: guarda(Trace()),
            recipe: Recipe(package: paquete, runtime: runtime(porDefecto), publishers: [:]),
            onEvent: { eventos.append($0) })

        let outcome = try await pipeline.runOnce()

        #expect(llamadas.count == 1)
        #expect(outcome == PassOutcome(processed: 0, deferred: 2))
        #expect(ledger.failures.isEmpty)
        #expect(eventos.values.map(label).contains("backendUnavailable"))
    }

    @Test("un fallo de transcripcion que la receta no recoge deja la nota fallida con su motivo")
    func falloDeTranscripcion() async throws {
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { _ throws(TranscriptionError) in throw .failed("audio corrupto") },
            sink: guarda(Trace()),
            recipe: Recipe(package: paquete, runtime: runtime(porDefecto), publishers: [:]))

        try await pipeline.runOnce()

        #expect(ledger.failures["a"]?.contains("audio corrupto") == true)
    }

    @Test("una receta que termina sin guardar deja la nota fallida y lo dice")
    func sinGuardar() async throws {
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(Trace()), sink: guarda(Trace()),
            recipe: Recipe(
                package: paquete, runtime: runtime { escriba in _ = try await escriba.transcribe() },
                publishers: [:]))

        try await pipeline.runOnce()

        #expect(ledger.doneKeys.isEmpty)
        #expect(ledger.failures["a"]?.contains("sin guardar") == true)
    }

    @Test("guardar antes de transcribir es un fallo de la receta, no una nota vacia")
    func guardarSinTranscribir() async throws {
        let ledger = MemoryLedger()
        let pasos = Trace<String>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(pasos), sink: guarda(pasos),
            recipe: Recipe(
                package: paquete, runtime: runtime { escriba in try await escriba.save() },
                publishers: [:]))

        try await pipeline.runOnce()

        #expect(pasos.values.isEmpty)
        #expect(ledger.failures["a"]?.contains("antes de transcribir") == true)
    }

    @Test("publicar en un conector que no existe falla con un mensaje claro")
    func conectorInexistente() async throws {
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(Trace()), sink: guarda(Trace()),
            recipe: Recipe(
                package: paquete,
                runtime: runtime { escriba in
                    _ = try await escriba.transcribe()
                    try await escriba.save()
                    try await escriba.publish("nada")
                },
                publishers: [:]))

        try await pipeline.runOnce()

        #expect(ledger.failures["a"]?.contains("no hay ningún conector «nada»") == true)
    }

    @Test("una receta que falla tambien deja su traza, con el error")
    func trazaDelFallo() async throws {
        let eventos = Trace<PipelineEvent>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(Trace()), sink: guarda(Trace()),
            recipe: Recipe(
                package: paquete,
                runtime: runtime { escriba in
                    escriba.log("antes de romper")
                    throw RecipeError.failed("se rompio en la linea 3")
                },
                publishers: [:]),
            onEvent: { eventos.append($0) })

        try await pipeline.runOnce()

        let traza = try #require(trazas(eventos).first)
        #expect(traza.error?.contains("se rompio en la linea 3") == true)
        #expect(traza.logs == ["antes de romper"])
        #expect(ledger.failures["a"]?.contains("se rompio en la linea 3") == true)
    }

    @Test("la receta recibe el audio de la grabacion y los conectores disponibles")
    func loQueRecibe() async throws {
        let recibido = Trace<String>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(Trace()), sink: guarda(Trace()),
            recipe: Recipe(
                package: paquete,
                runtime: runtime { escriba in
                    recibido.append(escriba.audio.key)
                    recibido.append(escriba.connectors.sorted().joined(separator: ","))
                    _ = try await escriba.transcribe()
                    try await escriba.save()
                },
                publishers: ["okf": publica(Trace(), en: "okf"), "notion": publica(Trace(), en: "notion")]))

        try await pipeline.runOnce()

        #expect(recibido.values == ["a", "notion,okf"])
    }
}
