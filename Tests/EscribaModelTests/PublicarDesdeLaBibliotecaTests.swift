import Foundation
import Synchronization
import Testing
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaStore

@testable import EscribaModel

private nonisolated func sandbox() throws -> (URL, Store) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "escriba-publicar-\(UUID().uuidString)")
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

private enum FakeError: Error { case caido }

private final class Publicador: Sendable {
    let enviados = Mutex<[String]>([])

    var sink: Sink {
        { recording, transcript in
            self.enviados.withLock { $0.append("\(recording.key): \(transcript.rendered)") }
            return URL(string: "https://notion.so/pg")!
        }
    }

    var registro: [String] { enviados.withLock { $0 } }
}

@MainActor
@Suite("Publicar en Notion desde la biblioteca")
struct PublicarDesdeLaBibliotecaTests {
    @Test("publicar a mano manda la ultima transcripcion")
    func publicaAMano() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])

        try await modelo.publish(guardada, to: "c1")

        #expect(publicador.registro == ["a: Hola"])
        #expect(modelo.canPublish(to: "c1"))
    }

    @Test("sin Notion configurado, publicar dice por que no puede")
    func sinConector() async throws {
        let (base, store) = try sandbox()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let modelo = LibraryModel(store: store)

        await #expect(throws: LibraryModelError.self) {
            try await modelo.publish(guardada, to: "c1")
        }
        #expect(!modelo.canPublish(to: "c1"))
    }

    @Test("si el conector falla al publicar a mano, el error llega al que pulso el boton")
    func publicarFalla() async throws {
        let (base, store) = try sandbox()
        let guardada = try store.save(
            try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let roto: Sink = { _, _ in throw FakeError.caido }
        let modelo = LibraryModel(store: store, publishers: ["c1": roto])

        await #expect(throws: FakeError.self) {
            try await modelo.publish(guardada, to: "c1")
        }
        #expect(!modelo.isPublishing("a", to: "c1"))
    }

    @Test("si republicar tras una correccion falla, la biblioteca lo cuenta en su estado")
    func republicarFalla() async throws {
        let (base, store) = try sandbox()
        _ = try store.save(try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        try store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)
        let roto: Sink = { _, _ in throw FakeError.caido }
        let modelo = LibraryModel(store: store, publishers: ["c1": roto])

        try await modelo.applyCorrection(Transcript(text: "Hola corregido"), to: "a")

        guard case .problem(let detalle) = modelo.status else {
            Issue.record("el estado deberia ser un problema, es \(modelo.status)")
            return
        }
        #expect(detalle.contains("c1"))
        #expect(detalle.contains("caido"))
    }

    @Test("corregir hablantes reescribe la pagina que ya existia en Notion")
    func republicaLoPublicado() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        _ = try store.save(try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        try store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])

        try await modelo.applyCorrection(Transcript(text: "Hola corregido"), to: "a")

        #expect(publicador.registro == ["a: Hola corregido"])
    }

    @Test("corregir no publica lo que nunca estuvo en Notion")
    func noPublicaLoNoPublicado() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        _ = try store.save(try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])

        try await modelo.applyCorrection(Transcript(text: "Hola corregido"), to: "a")

        #expect(publicador.registro.isEmpty)
    }

    @Test("corregir republica en cada conector donde ya estaba, y solo en esos")
    func republicaPorConector() async throws {
        let (base, store) = try sandbox()
        let uno = Publicador()
        let dos = Publicador()
        _ = try store.save(try grabacion(in: base, key: "a"), Transcript(text: "Hola"), backend: "wk")
        try store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)
        try store.markPublishFailed(key: "a", connector: "c2", error: "sin permiso")
        let modelo = LibraryModel(store: store, publishers: ["c1": uno.sink, "c2": dos.sink])

        try await modelo.applyCorrection(Transcript(text: "Hola corregido"), to: "a")

        #expect(uno.registro == ["a: Hola corregido"])
        #expect(dos.registro.isEmpty)
    }

    @Test("una grabacion sin transcripcion no se publica")
    func sinTranscripcion() async throws {
        let (base, store) = try sandbox()
        let publicador = Publicador()
        try await store.register([try grabacion(in: base, key: "a")])
        let pendiente = try #require(try store.recording(for: "a"))
        let modelo = LibraryModel(store: store, publishers: ["c1": publicador.sink])

        await #expect(throws: LibraryModelError.self) {
            try await modelo.publish(pendiente, to: "c1")
        }
        #expect(publicador.registro.isEmpty)
    }
}
