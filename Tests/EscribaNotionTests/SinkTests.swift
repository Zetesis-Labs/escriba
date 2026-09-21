import Foundation
import Synchronization
import Testing
import EscribaCore
import EscribaEngine

@testable import EscribaNotion

private let grabacion = Recording(
    url: URL(fileURLWithPath: "/Notas/a.m4a"), startedAt: Date(timeIntervalSince1970: 1_000_000),
    key: "a")

private func exportacion() -> NotionExport {
    let fuente = NotionDataSource(
        id: "ds-1", databaseTitle: "Diario", title: "Notas",
        properties: [NotionProperty(name: "Nombre", type: "title")])
    return NotionExport(source: fuente, mapping: suggestedMapping(for: fuente))
}

private enum DiarioError: Error { case roto }

private final class Diario: Sendable {
    let anotado = Mutex<[String]>([])

    var journal: NotionJournal {
        NotionJournal(
            published: { key, page, _ in self.anotado.withLock { $0.append("ok(\(key), \(page.id))") } },
            failed: { key, error in self.anotado.withLock { $0.append("error(\(key), \(error))") } })
    }

    var registro: [String] { anotado.withLock { $0 } }
}

private func client(
    createPage: @escaping @Sendable (JSONValue) async throws(NotionError) -> NotionPageRef
) -> NotionClient {
    NotionClient(
        dataSources: { [] },
        createPage: createPage,
        updatePage: { _, _ in },
        appendBlocks: { _, _ in },
        childBlocks: { _ in [] },
        deleteBlock: { _ in },
        findPage: { _, _ in nil })
}

@Suite("El sink de Notion")
struct NotionSinkTests {
    @Test("publica la grabacion y deja constancia con la hora")
    func publica() async throws {
        let diario = Diario()
        let momento = Date(timeIntervalSince1970: 1_700_000_000)
        let sink = notionSink(
            export: exportacion(),
            client: client { _ in NotionPageRef(id: "pg-1", url: URL(string: "https://n/1")) },
            journal: diario.journal, now: { momento })

        let salida = try await sink(grabacion, Transcript(text: "Hola"))

        #expect(salida == URL(string: "https://n/1"))
        #expect(diario.registro == ["ok(a, pg-1)"])
    }

    @Test("si Notion falla el pipeline sigue y el fallo queda anotado para reintentar")
    func fallaSinTumbar() async throws {
        let diario = Diario()
        let sink = notionSink(
            export: exportacion(),
            client: client { _ throws(NotionError) in throw NotionError.unauthorized },
            journal: diario.journal)

        let salida = try await sink(grabacion, Transcript(text: "Hola"))

        #expect(salida == grabacion.url)
        #expect(diario.registro == ["error(a, Notion rechaza el token. Revísalo en Ajustes.)"])
    }

    @Test("si no puede saber si la pagina ya existia, no publica (evitaria duplicarla) y lo anota")
    func diarioIlegible() async throws {
        let diario = Diario()
        let creadas = Mutex(0)
        var journal = diario.journal
        journal.known = { _ in throw DiarioError.roto }
        let sink = notionSink(
            export: exportacion(),
            client: client { _ in
                creadas.withLock { $0 += 1 }
                return NotionPageRef(id: "pg-1", url: nil)
            },
            journal: journal)

        let salida = try await sink(grabacion, Transcript(text: "Hola"))

        #expect(salida == grabacion.url)
        #expect(creadas.withLock { $0 } == 0)
        #expect(diario.registro.first?.hasPrefix("error(a, no se pudo consultar si ya estaba publicado") == true)
    }

    @Test("combinado con los demas sinks, el de Notion nunca rompe la cadena")
    func noRompeLaCadena() async throws {
        let diario = Diario()
        let combinado = sinks(
            primary: { recording, _ in recording.url },
            also: notionSink(
                export: exportacion(),
                client: client { _ throws(NotionError) in throw NotionError.rateLimited },
                journal: diario.journal))

        let salida = try await combinado(grabacion, Transcript(text: "Hola"))

        #expect(salida == grabacion.url)
        #expect(diario.registro.first?.hasPrefix("error(a,") == true)
    }
}
