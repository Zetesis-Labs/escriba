import Foundation
import Synchronization
import Testing
import EscribaCore
import EscribaEngine
import EscribaStore

@testable import EscribaModel

private nonisolated func sandbox() throws -> (URL, Store) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "escriba-resumir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base, try Store(root: base.appending(path: "library")))
}

private nonisolated func grabacion(in base: URL, key: String) throws -> Recording {
    let url = base.appending(path: "source/\(key).m4a")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: url)
    return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000_000), key: key)
}

private enum FakeError: Error { case sinModelo }

private nonisolated let resumen = Digest(title: "Backups", summary: "Restore pendiente.", tags: ["backups"])

private final class Publicador: Sendable {
    let enviados = Mutex<[String]>([])

    var sink: Sink {
        { note in
            self.enviados.withLock {
                $0.append("\(note.recording.key): \(note.digest?.title ?? "sin resumen")")
            }
            return URL(string: "https://notion.so/pg")!
        }
    }

    var registro: [String] { enviados.withLock { $0 } }
}

private final class Puerta: Sendable {
    private let esperando = Mutex<[CheckedContinuation<Void, Never>]>([])

    func esperar() async {
        await withCheckedContinuation { continuation in
            esperando.withLock { $0.append(continuation) }
        }
    }

    func abrir() {
        for continuation in esperando.withLock({ let todas = $0; $0 = []; return todas }) {
            continuation.resume()
        }
    }
}

@MainActor
@Suite("Resumir desde la biblioteca")
struct ResumirDesdeLaBibliotecaTests {
    @Test("dos peticiones a la vez no resumen dos veces la misma grabacion")
    func unaCadaVez() async throws {
        let (base, store) = try sandbox()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let puerta = Puerta()
        let llamadas = Mutex(0)
        let modelo = LibraryModel(store: store, digester: { _ in
            llamadas.withLock { $0 += 1 }
            await puerta.esperar()
            return resumen
        })

        let primera = Task { try await modelo.summarize(guardada) }
        while llamadas.withLock({ $0 }) == 0 { await Task.yield() }

        await #expect(throws: LibraryModelError.alreadySummarizing) {
            try await modelo.summarize(guardada)
        }
        puerta.abrir()
        _ = try await primera.value

        #expect(llamadas.withLock { $0 } == 1)
        #expect(!modelo.isSummarizing("a"))
    }

    @Test("publicar por primera vez ya lleva el resumen, no solo republicar")
    func primeraPublicacionLlevaResumen() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk",
            digest: resumen)
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])

        try await modelo.publish(guardada, to: "c1")

        #expect(publicador.registro == ["a: Backups"])
    }

    @Test("elegir otra version republica con el resumen de esa version")
    func elegirVersionLlevaSuResumen() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "v1"), backend: "wk",
            digest: resumen)
        try await store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk")
        try store.markPublished(
            key: "a", connector: "c1", pageId: "pg", url: nil, at: Date(timeIntervalSince1970: 1))
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])
        let primera = try #require(try await store.versions(for: "a").first)

        try await modelo.choose(version: primera.id, for: "a")

        #expect(publicador.registro == ["a: Backups"])
    }

    @Test("quitar el resumen republica sin el, para que el conector no lo conserve")
    func quitarResumenRepublica() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk",
            digest: resumen)
        try store.markPublished(
            key: "a", connector: "c1", pageId: "pg", url: nil, at: Date(timeIntervalSince1970: 1))
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])

        try await modelo.forgetSummary("a")

        #expect(publicador.registro == ["a: sin resumen"])
    }

    @Test("una grabacion sin transcripcion todavia no se puede resumir")
    func sinTranscripcion() async throws {
        let (base, store) = try sandbox()
        try await store.register([try grabacion(in: base, key: "a")])
        let stored = try #require(try store.recording(for: "a"))
        let modelo = LibraryModel(store: store, digester: { _ in resumen })

        await #expect(throws: LibraryModelError.nothingToSummarize) {
            try await modelo.summarize(stored)
        }
    }
    @Test("resumir a mano guarda el resumen y republica donde ya estaba")
    func resumirRepublica() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        try store.markPublished(
            key: "a", connector: "c1", pageId: "pg", url: nil, at: Date(timeIntervalSince1970: 1))
        let modelo = LibraryModel(
            store: store, digester: { _ in resumen }, publishers: ["c1": publicador.sink])

        let devuelto = try await modelo.summarize(guardada)

        #expect(devuelto == resumen)
        #expect(try await store.digest(for: "a") == resumen)
        #expect(publicador.registro == ["a: Backups"])
        #expect(!modelo.isSummarizing("a"))
    }

    @Test("sin resumidor configurado, la biblioteca lo dice y no lo esconde")
    func sinResumidor() async throws {
        let (base, store) = try sandbox()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let modelo = LibraryModel(store: store)

        #expect(!modelo.canSummarize)
        await #expect(throws: LibraryModelError.summaryUnavailable) {
            try await modelo.summarize(guardada)
        }
    }

    @Test("si el modelo falla al resumir a mano, el error llega a quien lo pidio")
    func falloAMano() async throws {
        let (base, store) = try sandbox()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let modelo = LibraryModel(store: store, digester: { _ in throw FakeError.sinModelo })

        await #expect(throws: FakeError.self) { try await modelo.summarize(guardada) }
        #expect(try await store.digest(for: "a") == nil)
        #expect(!modelo.isSummarizing("a"))
    }

    @Test("reprocesar resume la version nueva, y si el resumen falla la version se guarda igual")
    func reprocesarResume() async throws {
        let (base, store) = try sandbox()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "v1"), backend: "wk")
        let modelo = LibraryModel(
            store: store, reprocess: { _, _ in Transcript(text: "v2") }, digester: { _ in resumen })

        try await modelo.reprocess(guardada, options: TranscriptionOptions(language: "es"))

        #expect(try await store.transcript(for: "a")?.text == "v2")
        #expect(try await store.digest(for: "a") == resumen)

        let roto = LibraryModel(
            store: store, reprocess: { _, _ in Transcript(text: "v3") },
            digester: { _ in throw FakeError.sinModelo })
        try await roto.reprocess(guardada, options: TranscriptionOptions(language: "es"))

        #expect(try await store.transcript(for: "a")?.text == "v3")
        #expect(try await store.digest(for: "a") == nil)
    }

    @Test("renombrar un hablante conserva el resumen en la version corregida")
    func correccionConservaResumen() async throws {
        let (base, store) = try sandbox()
        let diarizada = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, speaker: "SPEAKER_00", text: "Hola")
        ])
        try store.save(try grabacion(in: base, key: "a"), diarizada, backend: "wk", digest: resumen)
        let modelo = LibraryModel(store: store)

        try await modelo.applyCorrection(diarizada.renaming("SPEAKER_00", to: "Rubén"), to: "a")

        #expect(try await store.digest(for: "a") == resumen)
    }

    @Test("quitar el resumen lo borra de la version vigente")
    func quitarResumen() async throws {
        let (base, store) = try sandbox()
        try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk",
            digest: resumen)
        let modelo = LibraryModel(store: store)

        try await modelo.forgetSummary("a")

        #expect(try await modelo.digest(for: "a") == nil)
    }
}
