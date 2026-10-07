import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let resumen = Digest(title: "Hola", summary: "Adiós", tags: ["x"])

private func resumidor(_ steps: Trace<String>, answer: Digest? = resumen) -> Enricher {
    { _, _ in
        steps.append("resume")
        return answer
    }
}

private func entregas(_ steps: Trace<String>, into notes: Trace<Note>? = nil) -> Sink {
    { note in
        steps.append("entrega")
        notes?.append(note)
        return URL(fileURLWithPath: "/salida/\(note.recording.key).txt")
    }
}

private func transcribe(_ steps: Trace<String>, text: String = "hola") -> TranscriptionBackend {
    backend { _ in
        steps.append("transcribe")
        return Transcript(text: text)
    }
}

@Suite("Capacidades que recuerdan lo hecho")
struct MemoriaTests {
    @Test("si la app se cierra tras transcribir, la pasada siguiente no vuelve a transcribir")
    func cierreTrasTranscribir() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "ya transcrita"))
        let pasos = Trace<String>()
        let notas = Trace<Note>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(pasos), sink: entregas(pasos, into: notas), memory: memoria.port)

        let outcome = try await pipeline.runOnce()

        #expect(pasos.values == ["entrega"])
        #expect(notas.values.map(\.transcript.text) == ["ya transcrita"])
        #expect(outcome == PassOutcome(processed: 1, deferred: 0))
        #expect(ledger.doneKeys == ["a"])
    }

    @Test("una nota que fallo al entregarse se reintenta sin volver a transcribir")
    func reintentoTrasFalloDeEntrega() async throws {
        let memoria = MemoryNotes()
        let llamadas = Trace<URL>()
        let backend = backend { url in
            llamadas.append(url)
            return Transcript(text: "hola")
        }
        let primera = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port, backend: backend,
            sink: { _ in throw FakeError.sinkBroken }, memory: memoria.port)
        let reintento = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port, backend: backend,
            sink: entregas(Trace()), memory: memoria.port)

        try await primera.runOnce()
        try await reintento.runOnce()

        #expect(llamadas.count == 1)
    }

    @Test("la transcripcion se guarda antes de resumir y el resumen va a esa misma version")
    func ordenDeGuardado() async throws {
        let pasos = Trace<String>()
        let memoria = MemoryNotes(steps: pasos)
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(pasos), sink: entregas(pasos),
            enrich: resumidor(pasos), memory: memoria.port)

        try await pipeline.runOnce()

        #expect(pasos.values == [
            "transcribe", "guarda transcripcion", "resume", "guarda resumen v1", "entrega",
        ])
        #expect(memoria.kept("a")?.digest == resumen)
    }

    @Test("un resumen recordado no se vuelve a pedir y llega al destino")
    func resumenRecordado() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "hola"), digest: resumen)
        let pasos = Trace<String>()
        let notas = Trace<Note>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(pasos), sink: entregas(pasos, into: notas),
            enrich: resumidor(pasos), memory: memoria.port)

        try await pipeline.runOnce()

        #expect(pasos.values == ["entrega"])
        #expect(notas.values.map(\.digest) == [resumen])
    }

    @Test("una transcripcion recordada sin resumen se resume y el resumen va a su version")
    func transcripcionRecordadaSinResumen() async throws {
        let pasos = Trace<String>()
        let memoria = MemoryNotes(steps: pasos)
        memoria.remember("a", Transcript(text: "hola"))
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: transcribe(pasos), sink: entregas(pasos),
            enrich: resumidor(pasos), memory: memoria.port)

        try await pipeline.runOnce()

        #expect(pasos.values == ["resume", "guarda resumen v1", "entrega"])
    }

    @Test("si el resumen falla no se guarda nada y la nota sigue sin resumen")
    func resumenFallido() async throws {
        let pasos = Trace<String>()
        let memoria = MemoryNotes(steps: pasos)
        let notas = Trace<Note>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(pasos), sink: entregas(pasos, into: notas),
            enrich: resumidor(pasos, answer: nil), memory: memoria.port)

        try await pipeline.runOnce()

        #expect(pasos.values == ["transcribe", "guarda transcripcion", "resume", "entrega"])
        #expect(notas.values.map(\.digest) == [nil])
        #expect(ledger.doneKeys == ["a"])
    }

    @Test("con el backend caido no se guarda nada y se aplaza igual que sin memoria")
    func backendCaido() async throws {
        let pasos = Trace<String>()
        let memoria = MemoryNotes(steps: pasos)
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a"), recording("b", minute: 1)]), ledger: ledger.port,
            backend: backend { _ throws(TranscriptionError) in throw .backendUnavailable("apagado") },
            sink: entregas(pasos), memory: memoria.port)

        let outcome = try await pipeline.runOnce()

        #expect(pasos.values.isEmpty)
        #expect(outcome == PassOutcome(processed: 0, deferred: 2))
        #expect(ledger.failures.isEmpty)
    }

    @Test("un fallo de transcripcion no guarda nada y se anota con su motivo")
    func falloDeTranscripcion() async throws {
        let pasos = Trace<String>()
        let memoria = MemoryNotes(steps: pasos)
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { _ throws(TranscriptionError) in throw .failed("audio corrupto") },
            sink: entregas(pasos), memory: memoria.port)

        try await pipeline.runOnce()

        #expect(pasos.values.isEmpty)
        #expect(ledger.failures["a"]?.contains("audio corrupto") == true)
    }

    @Test("si no se puede guardar la transcripcion, la nota queda fallida y no se entrega")
    func guardarQueFalla() async throws {
        let memoria = MemoryNotes()
        memoria.breakKeeping()
        let pasos = Trace<String>()
        let ledger = MemoryLedger()
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(pasos), sink: entregas(pasos), memory: memoria.port,
            onEvent: { eventos.append($0) })

        try await pipeline.runOnce()

        #expect(pasos.values == ["transcribe"])
        #expect(ledger.doneKeys.isEmpty)
        #expect(ledger.failures.keys.contains("a"))
        #expect(eventos.values.map(label).contains("failed"))
    }

    @Test("si la memoria no responde, la nota falla sin pagar otra transcripcion")
    func memoriaCaida() async throws {
        let memoria = MemoryNotes()
        memoria.breakRecall()
        let pasos = Trace<String>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: transcribe(pasos), sink: entregas(pasos), memory: memoria.port)

        try await pipeline.runOnce()

        #expect(pasos.values.isEmpty)
        #expect(ledger.failures.keys.contains("a"))
    }

    @Test("con memoria se anuncian los mismos eventos que sin ella")
    func mismosEventos() async throws {
        let conMemoria = Trace<PipelineEvent>()
        let sinMemoria = Trace<PipelineEvent>()
        let recordada = MemoryNotes()
        recordada.remember("a", Transcript(text: "hola"))

        for (eventos, memoria) in [(conMemoria, recordada.port), (sinMemoria, nil)] {
            let pipeline = Pipeline(
                source: source([recording("a")]), ledger: MemoryLedger().port,
                backend: transcribe(Trace()), sink: entregas(Trace()), memory: memoria,
                onEvent: { eventos.append($0) })
            try await pipeline.runOnce()
        }

        #expect(conMemoria.values.map(label) == sinMemoria.values.map(label))
        #expect(conMemoria.values.map(label) == ["scanned", "passStarted", "transcribing", "transcribed"])
    }
}
