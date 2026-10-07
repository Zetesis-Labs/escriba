import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

@Suite("Pipeline sobre puertos falsos")
struct PipelineTests {
    @Test("transcribe lo pendiente, lo entrega al sink y lo asienta en el ledger")
    func casoFeliz() async throws {
        let ledger = MemoryLedger()
        let escrito = Trace<String>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { _ in Transcript(text: "hola") }, sink: sink(into: escrito))

        let outcome = try await pipeline.runOnce()

        #expect(outcome == PassOutcome(processed: 1, deferred: 0))
        #expect(escrito.values == ["hola"])
        #expect(ledger.doneKeys == ["a"])
    }

    @Test("lo asentado no se vuelve a transcribir")
    func idempotencia() async throws {
        let ledger = MemoryLedger()
        let llamadas = Trace<URL>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { url in
                llamadas.append(url)
                return Transcript(text: "x")
            }, sink: sink(into: Trace()))

        try await pipeline.runOnce()
        let segunda = try await pipeline.runOnce()

        #expect(llamadas.count == 1)
        #expect(segunda.processed == 0)
    }

    @Test("procesa por orden de inicio de grabacion, no por orden de escaneo")
    func ordenCronologico() async throws {
        let ledger = MemoryLedger()
        let llamadas = Trace<URL>()
        let pipeline = Pipeline(
            source: source([recording("tarde", minute: 10), recording("pronto", minute: 1)]),
            ledger: ledger.port,
            backend: backend { url in
                llamadas.append(url)
                return Transcript(text: "x")
            }, sink: sink(into: Trace()))

        try await pipeline.runOnce()

        #expect(llamadas.values.map(\.lastPathComponent) == ["pronto.m4a", "tarde.m4a"])
    }

    @Test("un backend caido aplaza sus grabaciones sin volver a llamarlo y no consume intentos")
    func backendCaido() async throws {
        let ledger = MemoryLedger()
        let llamadas = Trace<URL>()
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a"), recording("b", minute: 1)]), ledger: ledger.port,
            backend: backend { url throws(TranscriptionError) in
                llamadas.append(url)
                throw .backendUnavailable("apagado")
            },
            sink: sink(into: Trace()), onEvent: { eventos.append($0) })

        let outcome = try await pipeline.runOnce()

        #expect(llamadas.count == 1)
        #expect(outcome == PassOutcome(processed: 0, deferred: 2))
        #expect(ledger.doneKeys.isEmpty)
        #expect(ledger.failures.isEmpty)
        #expect(eventos.values.map(label).contains("backendUnavailable"))
    }

    @Test("un motor caido solo retiene sus grabaciones: las de otro motor se transcriben en la misma pasada")
    func motorCaidoNoBloqueaAOtros() async throws {
        let ledger = MemoryLedger()
        let llamadas = Trace<String>()
        let eventos = Trace<PipelineEvent>()
        let caido = ["antigua.m4a", "otra-remota.m4a"]
        let enrutado = TranscriptionBackend(
            name: "segun la grabacion",
            transcribe: { url throws(TranscriptionError) in
                llamadas.append(url.lastPathComponent)
                if caido.contains(url.lastPathComponent) { throw .backendUnavailable("sin clave") }
                return Transcript(text: "local")
            },
            route: { url in caido.contains(url.lastPathComponent) ? "remoto" : "local" })
        let pipeline = Pipeline(
            source: source([
                recording("antigua", minute: 0), recording("nueva", minute: 1),
                recording("otra-remota", minute: 2),
            ]),
            ledger: ledger.port, backend: enrutado, sink: sink(into: Trace()),
            onEvent: { eventos.append($0) })

        let outcome = try await pipeline.runOnce()

        #expect(llamadas.values == ["antigua.m4a", "nueva.m4a"])
        #expect(ledger.doneKeys == ["nueva"])
        #expect(ledger.failures.isEmpty)
        #expect(outcome == PassOutcome(processed: 1, deferred: 2))
        #expect(eventos.values.map(label).filter { $0 == "backendUnavailable" }.count == 1)
    }

    @Test("un fallo de transcripcion se anota con su motivo y la pasada sigue con las demas")
    func falloDeTranscripcion() async throws {
        let ledger = MemoryLedger()
        let escrito = Trace<String>()
        let pipeline = Pipeline(
            source: source([recording("rota"), recording("sana", minute: 1)]), ledger: ledger.port,
            backend: backend { url throws(TranscriptionError) in
                if url.lastPathComponent == "rota.m4a" { throw .failed("audio corrupto") }
                return Transcript(text: "bien")
            }, sink: sink(into: escrito))

        let outcome = try await pipeline.runOnce()

        #expect(outcome.processed == 1)
        #expect(ledger.failures["rota"]?.contains("audio corrupto") == true)
        #expect(ledger.doneKeys == ["sana"])
        #expect(escrito.values == ["bien"])
    }

    @Test("un sink que falla deja la grabacion como fallida, no como hecha")
    func falloDelSink() async throws {
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { _ in Transcript(text: "x") },
            sink: { _ in throw FakeError.sinkBroken })

        let outcome = try await pipeline.runOnce()

        #expect(outcome.processed == 0)
        #expect(ledger.doneKeys.isEmpty)
        #expect(ledger.failures.keys.contains("a"))
    }

    @Test("una grabacion que aun no esta lista se deja para el proximo ciclo sin tocar el ledger")
    func sinAsentar() async throws {
        let ledger = MemoryLedger()
        let llamadas = Trace<URL>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { url in
                llamadas.append(url)
                return Transcript(text: "x")
            }, sink: sink(into: Trace()), readiness: { _ in .growing })

        let outcome = try await pipeline.runOnce()

        #expect(llamadas.count == 0)
        #expect(outcome == PassOutcome(processed: 0, deferred: 1))
        #expect(ledger.doneKeys.isEmpty)
        #expect(ledger.failures.isEmpty)
    }

    @Test("si la fuente no se puede leer, la pasada falla y lo anuncia")
    func fuenteIlegible() async throws {
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: brokenSource(), ledger: MemoryLedger().port,
            backend: backend { _ in Transcript(text: "x") }, sink: sink(into: Trace()),
            onEvent: { eventos.append($0) })

        await #expect(throws: FakeError.self) { try await pipeline.runOnce() }
        #expect(eventos.values.map(label) == ["scanFailed"])
    }

    @Test("si el ledger no responde, la pasada falla en vez de retranscribir todo")
    func ledgerCaido() async throws {
        let ledger = MemoryLedger()
        ledger.breakIt()
        let llamadas = Trace<URL>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: ledger.port,
            backend: backend { url in
                llamadas.append(url)
                return Transcript(text: "x")
            }, sink: sink(into: Trace()))

        await #expect(throws: FakeError.self) { try await pipeline.runOnce() }
        #expect(llamadas.count == 0)
    }

    @Test("si el ledger no puede anotar un fallo, la pasada termina igual y lo anuncia")
    func anotarFalloQueFalla() async throws {
        let ledger = MemoryLedger()
        ledger.breakMarking()
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a"), recording("b", minute: 1)]), ledger: ledger.port,
            backend: backend { _ throws(TranscriptionError) in throw .failed("corrupto") },
            sink: sink(into: Trace()), onEvent: { eventos.append($0) })

        let outcome = try await pipeline.runOnce()

        #expect(outcome == PassOutcome(processed: 0, deferred: 0))
        #expect(eventos.values.map(label).filter { $0 == "failed" }.count == 2)
    }

    @Test("anuncia el escaneo, el arranque, cada transcripcion y su resultado, en ese orden")
    func eventos() async throws {
        let eventos = Trace<PipelineEvent>()
        let pipeline = Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: backend { _ in Transcript(text: "x") }, sink: sink(into: Trace()),
            onEvent: { eventos.append($0) })

        try await pipeline.runOnce()
        try await pipeline.runOnce()

        #expect(eventos.values.map(label) == [
            "scanned", "passStarted", "transcribing", "transcribed",
            "scanned", "idle",
        ])
    }
}
