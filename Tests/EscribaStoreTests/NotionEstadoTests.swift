import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaSystemKit
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-publicaciones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func recording(_ key: String) throws -> Recording {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000_000), key: key)
    }
}

@Suite("Rastro de lo publicado en cada conector")
struct PublicacionesTests {
    @Test("una grabacion recien guardada no esta publicada en ningun sitio")
    func sinPublicar() async throws {
        let caja = try Sandbox()
        let guardada = try caja.store.save(
            try caja.recording("a"), Transcript(text: "Hola"), backend: "whisperkit")

        #expect(guardada.publications.isEmpty)
    }

    @Test("publicar deja pagina, enlace y hora en su conector, y borra el error anterior")
    func publicada() async throws {
        let caja = try Sandbox()
        let momento = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try caja.store.save(try caja.recording("a"), Transcript(text: "Hola"), backend: "wk")

        try caja.store.markPublishFailed(key: "a", connector: "c1", error: "Notion devolvió 500")
        try caja.store.markPublished(
            key: "a", connector: "c1", pageId: "pg-1", url: URL(string: "https://notion.so/pg-1"),
            at: momento)

        let fila = try #require(try caja.store.recording(for: "a"))
        let publicacion = try #require(fila.publication(in: "c1"))
        #expect(publicacion.pageId == "pg-1")
        #expect(publicacion.url == URL(string: "https://notion.so/pg-1"))
        #expect(publicacion.syncedAt == momento)
        #expect(publicacion.error == nil)
        #expect(fila.publications.count == 1)
    }

    @Test("cada conector lleva su propio rastro")
    func porConector() async throws {
        let caja = try Sandbox()
        _ = try caja.store.save(try caja.recording("a"), Transcript(text: "Hola"), backend: "wk")

        try caja.store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)
        try caja.store.markPublishFailed(key: "a", connector: "c2", error: "sin permiso")

        let fila = try #require(try caja.store.recording(for: "a"))
        #expect(fila.publication(in: "c1")?.isPublished == true)
        #expect(fila.publication(in: "c2")?.isPublished == false)
        #expect(fila.publication(in: "c2")?.error == "sin permiso")
        #expect(try caja.store.recordings().first?.publications.count == 2)
    }

    @Test("un fallo posterior conserva la pagina para poder reintentar sobre ella")
    func falloTrasPublicar() async throws {
        let caja = try Sandbox()
        _ = try caja.store.save(try caja.recording("a"), Transcript(text: "Hola"), backend: "wk")
        try caja.store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)

        try caja.store.markPublishFailed(key: "a", connector: "c1", error: "se cayo la red")

        let publicacion = try #require(try caja.store.recording(for: "a")?.publication(in: "c1"))
        #expect(publicacion.error == "se cayo la red")
        #expect(publicacion.pageId == "pg-1")
    }

    @Test("olvidar la publicacion de un conector deja la fila sin rastro en ese conector y no toca los demas")
    func olvidar() throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(try sandbox.recording("a"), Transcript(text: "x"), backend: "wk")
        try sandbox.store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)
        try sandbox.store.markPublished(key: "a", connector: "c2", pageId: "pg-2", url: nil, at: .now)

        try sandbox.store.removePublication(key: "a", connector: "c1")

        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.publication(in: "c1") == nil)
        #expect(fila.publication(in: "c2")?.pageId == "pg-2")
    }

    @Test("marcar una clave que no existe no revienta ni inventa filas")
    func claveDesconocida() async throws {
        let caja = try Sandbox()

        try caja.store.markPublished(key: "fantasma", connector: "c1", pageId: "pg-1", url: nil, at: .now)

        #expect(try caja.store.recording(for: "fantasma") == nil)
    }

    @Test("borrar la grabacion de la biblioteca se lleva su rastro de publicaciones")
    func borradoEnCascada() async throws {
        let caja = try Sandbox()
        _ = try caja.store.save(try caja.recording("a"), Transcript(text: "Hola"), backend: "wk")
        try caja.store.markPublished(key: "a", connector: "c1", pageId: "pg-1", url: nil, at: .now)

        try await caja.store.discard(key: "a")

        #expect(try caja.store.recordings().isEmpty)
    }
}
