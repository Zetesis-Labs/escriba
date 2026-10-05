import Foundation
import Synchronization
import Testing
import EscribaCore

@testable import EscribaNotion

private final class Espia: Sendable {
    private let llamadas = Mutex<[String]>([])
    private let existente: NotionPageRef?
    private let updateFails: NotionError?

    init(existente: NotionPageRef?, updateFails: NotionError? = nil) {
        self.existente = existente
        self.updateFails = updateFails
    }

    func anota(_ texto: String) { llamadas.withLock { $0.append(texto) } }
    var registro: [String] { llamadas.withLock { $0 } }

    var client: NotionClient {
        NotionClient(
            dataSources: { [] },
            createPage: { body throws(NotionError) in
                self.anota("crear(\(body["children"]?.count ?? 0))")
                return NotionPageRef(id: "pg-nueva", url: URL(string: "https://n/nueva"))
            },
            updatePage: { id, _ throws(NotionError) in
                self.anota("actualizar(\(id))")
                if let fallo = self.updateFails { throw fallo }
            },
            appendBlocks: { id, body throws(NotionError) in
                self.anota("añadir(\(id), \(body["children"]?.count ?? 0))")
            },
            childBlocks: { id throws(NotionError) in
                self.anota("hijos(\(id))")
                return ["b-1", "b-2"]
            },
            deleteBlock: { id throws(NotionError) in self.anota("borrar(\(id))") },
            findPage: { _, _ throws(NotionError) in self.existente })
    }
}

private func exportacion(clave: Bool = true) -> NotionExport {
    let fuente = NotionDataSource(
        id: "ds-1", databaseTitle: "Diario", title: "Notas",
        properties: [
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Clave", type: "rich_text"),
        ])
    var columnas = suggestedColumns(for: fuente)
    if !clave { columnas["Clave"] = nil }
    return NotionExport(source: fuente, columns: columnas, body: NotionExport.standardBody)
}

private func pagina(turnos: Int) -> NotionPage {
    notionPage(
        for: Note(
            recording: Recording(url: URL(fileURLWithPath: "/a.m4a"), startedAt: .now, key: "a"),
            transcript: Transcript(segments: (0..<turnos).map {
                TranscriptSegment(
                    start: Double($0), end: Double($0) + 1, speaker: "H\($0)", text: "turno \($0)")
            })),
        as: exportacion())
}

@Suite("Publicar en Notion")
struct PublicacionTests {
    @Test("una grabacion nueva crea la pagina con la primera tanda dentro")
    func creacion() async throws {
        let espia = Espia(existente: nil)
        let ref = try await publish(pagina(turnos: 3), as: exportacion(), using: espia.client)

        #expect(ref.id == "pg-nueva")
        #expect(espia.registro == ["crear(3)"])
    }

    @Test("lo que no cabe en la creacion se añade en tandas de cien")
    func tandas() async throws {
        let espia = Espia(existente: nil)
        _ = try await publish(pagina(turnos: 250), as: exportacion(), using: espia.client)

        #expect(espia.registro == ["crear(100)", "añadir(pg-nueva, 100)", "añadir(pg-nueva, 50)"])
    }

    @Test("si la grabacion ya tiene pagina se reescribe, no se duplica")
    func reescritura() async throws {
        let espia = Espia(existente: NotionPageRef(id: "pg-vieja", url: URL(string: "https://n/vieja")))
        let ref = try await publish(pagina(turnos: 2), as: exportacion(), using: espia.client)

        #expect(ref.id == "pg-vieja")
        #expect(espia.registro == [
            "actualizar(pg-vieja)", "hijos(pg-vieja)", "borrar(b-1)", "borrar(b-2)",
            "añadir(pg-vieja, 2)",
        ])
    }

    @Test("si la biblioteca ya sabe la pagina, no hace falta clave en la base para no duplicar")
    func paginaConocida() async throws {
        let espia = Espia(existente: nil)
        let conocida = NotionPageRef(id: "pg-conocida", url: nil)

        let ref = try await publish(
            pagina(turnos: 1), as: exportacion(clave: false), using: espia.client, known: conocida)

        #expect(ref.id == "pg-conocida")
        #expect(espia.registro == [
            "actualizar(pg-conocida)", "hijos(pg-conocida)", "borrar(b-1)", "borrar(b-2)",
            "añadir(pg-conocida, 1)",
        ])
    }

    @Test("si el usuario borro la pagina en Notion, se crea otra en vez de fallar")
    func paginaBorradaEnNotion() async throws {
        let espia = Espia(existente: nil, updateFails: .notFound("Could not find page"))
        let conocida = NotionPageRef(id: "pg-borrada", url: nil)

        let ref = try await publish(
            pagina(turnos: 1), as: exportacion(), using: espia.client, known: conocida)

        #expect(ref.id == "pg-nueva")
        #expect(espia.registro == ["actualizar(pg-borrada)", "crear(1)"])
    }

    @Test("sin columna de clave no se busca duplicado y siempre crea")
    func sinClave() async throws {
        let espia = Espia(existente: NotionPageRef(id: "pg-vieja", url: nil))
        let ref = try await publish(pagina(turnos: 1), as: exportacion(clave: false), using: espia.client)

        #expect(ref.id == "pg-nueva")
        #expect(espia.registro == ["crear(1)"])
    }

    @Test("una exportacion sin nada en el titulo no vale")
    func exportacionInvalida() {
        var export = exportacion()
        #expect(export.isUsable)

        export.columns["Nombre"] = nil
        #expect(!export.isUsable)
    }
}
