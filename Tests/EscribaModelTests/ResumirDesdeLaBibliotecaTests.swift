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

@MainActor
@Suite("Resumir desde la biblioteca")
struct ResumirDesdeLaBibliotecaTests {
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
