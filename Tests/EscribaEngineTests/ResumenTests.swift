import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private func summarizer(
    capacity: Int = 1000,
    availability: @escaping @Sendable () -> SummaryAvailability = { .ready },
    into trace: Trace<DigestRequest>? = nil,
    answer: @escaping @Sendable (DigestRequest) throws(SummaryError) -> Digest
) -> Summarizer {
    Summarizer(name: "falso", capacity: capacity, availability: availability) { request throws(SummaryError) in
        trace?.append(request)
        return try answer(request)
    }
}

private func texto(_ request: DigestRequest) -> String {
    request.prompt
        .replacingOccurrences(of: DigestPrompt.request(text: ""), with: "")
        .replacingOccurrences(of: DigestPrompt.reduce(partials: []), with: "")
}

@Suite("Resumir una transcripcion")
struct ResumenTests {
    @Test("un texto que cabe se resume de una vez y sale normalizado")
    func unaPasada() async throws {
        let peticiones = Trace<DigestRequest>()
        let resumidor = summarizer(into: peticiones) { _ in
            Digest(title: "\"Reunión de backups.\"", summary: " Se habló de MinIO. ", tags: ["#Backups", "backups"])
        }

        let digest = try await resumidor.digest(of: "Hablamos de backups.", language: "es")

        #expect(digest == Digest(title: "Reunión de backups", summary: "Se habló de MinIO.", tags: ["backups"]))
        #expect(peticiones.count == 1)
        #expect(peticiones.values[0].prompt.contains("Hablamos de backups."))
        #expect(peticiones.values[0].instructions.contains("español"))
    }

    @Test("un texto largo se resume por trozos y luego se unen los parciales")
    func mapaYReduccion() async throws {
        let peticiones = Trace<DigestRequest>()
        let resumidor = summarizer(capacity: 200, into: peticiones) { request in
            request.prompt.contains("parciales")
                ? Digest(title: "Todo junto", summary: "Union", tags: ["final"])
                : Digest(title: "T", summary: "P", tags: ["x"])
        }
        let largo = (1...6).map { "Párrafo \($0) con bastante texto dentro." }.joined(separator: "\n")

        let digest = try await resumidor.digest(of: largo, language: nil)

        #expect(digest.title == "Todo junto")
        #expect(peticiones.count == 3)
        #expect(peticiones.values.last!.prompt.contains("Título: T"))
        #expect(peticiones.values.dropLast().allSatisfy { !$0.prompt.contains("parciales") })
    }

    @Test("cuando los parciales tampoco caben de una vez, se reducen por rondas")
    func reduccionEnCascada() async throws {
        let peticiones = Trace<DigestRequest>()
        let resumidor = summarizer(capacity: 200, into: peticiones) { request in
            request.prompt.contains("parciales")
                ? Digest(title: "Todo junto", summary: "Union", tags: ["final"])
                : Digest(title: "T", summary: "P", tags: ["x"])
        }
        let larguisimo = (1...40).map { "Párrafo \($0) con bastante texto dentro." }
            .joined(separator: "\n")

        let digest = try await resumidor.digest(of: larguisimo, language: "es")

        #expect(digest.title == "Todo junto")
        #expect(peticiones.values.filter { $0.prompt.contains("parciales") }.count > 1)
        #expect(peticiones.values.allSatisfy { texto($0).count <= 200 })
    }

    @Test("si ni reduciendo cabe, se dice que la grabacion es demasiado larga en vez de colgarse")
    func reduccionQueNoConverge() async {
        let resumidor = summarizer(capacity: 60) { _ in
            Digest(
                title: String(repeating: "t", count: 50), summary: String(repeating: "r", count: 50),
                tags: [])
        }
        let larguisimo = (1...30).map { "Párrafo \($0) con texto suficiente." }.joined(separator: "\n")

        await #expect(throws: SummaryError.self) {
            try await resumidor.digest(of: larguisimo, language: "es")
        }
    }

    @Test("un resumen vacio se trata como fallo, no se guarda como si fuera bueno")
    func resumenVacio() async {
        let resumidor = summarizer { _ in Digest(title: "  ", summary: "", tags: ["algo"]) }

        await #expect(throws: SummaryError.empty) {
            try await resumidor.digest(of: "Hola", language: "es")
        }
    }

    @Test("si el modelo no esta disponible no se llama y se dice por que")
    func noDisponible() async {
        let peticiones = Trace<DigestRequest>()
        let resumidor = summarizer(
            availability: { .unavailable("Apple Intelligence esta apagado") }, into: peticiones
        ) { _ in Digest(title: "no", summary: "no", tags: []) }

        await #expect(throws: SummaryError.unavailable("Apple Intelligence esta apagado")) {
            try await resumidor.digest(of: "Hola", language: "es")
        }
        #expect(peticiones.count == 0)
    }

    @Test("una transcripcion vacia no gasta una llamada")
    func sinTexto() async {
        let peticiones = Trace<DigestRequest>()
        let resumidor = summarizer(into: peticiones) { _ in Digest(title: "no", summary: "no", tags: []) }

        await #expect(throws: SummaryError.nothingToSummarize) {
            try await resumidor.digest(of: "  \n ", language: "es")
        }
        #expect(peticiones.count == 0)
    }

    @Test("el fallo del modelo se propaga a quien lo pidio a mano")
    func falloSePropaga() async {
        let resumidor = summarizer { _ throws(SummaryError) in throw SummaryError.failed("sin memoria") }

        await #expect(throws: SummaryError.failed("sin memoria")) {
            try await resumidor.digest(of: "Hola", language: "es")
        }
    }

    @Test("el pipeline entrega al destino la nota con su resumen")
    func laNotaLlevaElResumen() async throws {
        let recibido = Trace<Digest?>()
        let ledger = MemoryLedger()
        let pipeline = Pipeline(
            source: source([recording("a")]),
            ledger: ledger.port,
            backend: backend { _ in Transcript(text: "Hola") },
            sink: { note in
                recibido.append(note.digest)
                return note.recording.url
            },
            enrich: enricher(summarizer { _ in Digest(title: "Hola", summary: "Adiós", tags: ["x"]) }, language: "es"))

        try await pipeline.runOnce()

        #expect(recibido.values == [Digest(title: "Hola", summary: "Adiós", tags: ["x"])])
        #expect(ledger.doneKeys == ["a"])
    }

    @Test("sin resumidor, la nota viaja sin resumen y el destino no se entera")
    func sinResumidor() async throws {
        let recibido = Trace<Digest?>()
        let pipeline = Pipeline(
            source: source([recording("a")]),
            ledger: MemoryLedger().port,
            backend: backend { _ in Transcript(text: "Hola") },
            sink: { note in
                recibido.append(note.digest)
                return note.recording.url
            })

        try await pipeline.runOnce()

        #expect(recibido.values == [nil])
    }

    @Test("en el pipeline el fallo del resumen no tumba la pasada: se queda sin resumen")
    func enriquecerNoRompe() async {
        let roto = enricher(summarizer { _ throws(SummaryError) in throw SummaryError.failed("sin memoria") }, language: "es")
        let bueno = enricher(summarizer { _ in Digest(title: "Hola", summary: "Adiós", tags: []) }, language: "es")

        #expect(await roto(Transcript(text: "Hola")) == nil)
        #expect(await bueno(Transcript(text: "Hola"))?.title == "Hola")
    }
}
