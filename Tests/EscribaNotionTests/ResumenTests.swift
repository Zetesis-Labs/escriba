import Foundation
import Synchronization
import Testing
import EscribaCore

@testable import EscribaNotion

private let resumen = Digest(
    title: "Backups de cortes", summary: "Se revisa el restore.", tags: ["backups", "minio"])

private func grabacion(key: String = "2026-09-21 10-00-00") -> Recording {
    Recording(url: URL(fileURLWithPath: "/Notas/\(key).m4a"), startedAt: .distantPast, key: key)
}

private func base(_ properties: [NotionProperty]) -> NotionDataSource {
    NotionDataSource(id: "ds", databaseTitle: "D", title: "D", properties: properties)
}

@Suite("El resumen en Notion")
struct ResumenEnNotionTests {
    @Test("con resumen, la pagina se titula con el y sin el cae al arranque del texto")
    func titulo() {
        let conResumen = notionPage(
            for: grabacion(), transcript: Transcript(text: "Hola que tal"), digest: resumen)
        let sinResumen = notionPage(for: grabacion(), transcript: Transcript(text: "Hola que tal"))

        #expect(conResumen.title == "Backups de cortes")
        #expect(sinResumen.title == "Hola que tal")
    }

    @Test("el bloque /resumen escribe el resumen y desaparece si no hay")
    func bloqueDeResumen() {
        let plantilla = BodyTemplate([.summary, .transcript(.plain)])
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "Cuerpo"), digest: resumen)

        let conResumen = render(plantilla, for: pagina, transcript: Transcript(text: "Cuerpo"), audio: nil)
        #expect(conResumen.map(\.plainText) == ["Se revisa el restore.", "Cuerpo"])

        let sinResumen = render(
            plantilla, for: notionPage(for: grabacion(), transcript: Transcript(text: "Cuerpo")),
            transcript: Transcript(text: "Cuerpo"), audio: nil)
        #expect(sinResumen.map(\.plainText) == ["Cuerpo"])
    }

    @Test("el bloque /etiquetas las lista separadas por comas")
    func bloqueDeEtiquetas() {
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "x"), digest: resumen)
        let bloques = render(
            BodyTemplate([.field(.tags)]), for: pagina, transcript: Transcript(text: "x"), audio: nil)

        #expect(bloques.map(\.plainText) == ["Etiquetas: backups, minio"])
    }

    @Test("las etiquetas van a multi_select y el resumen a texto enriquecido")
    func propiedades() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Resumen", type: "rich_text"),
            NotionProperty(name: "Temas", type: "multi_select"),
        ])
        let mapeo = suggestedMapping(for: fuente)
        #expect(mapeo[.summary] == "Resumen")
        #expect(mapeo[.tags] == "Temas")

        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "x"), digest: resumen)
        let cuerpo = createPageBody(pagina, in: fuente, mapping: mapeo, timeZone: .gmt)

        #expect(cuerpo["properties"]?["Resumen"]?["rich_text"]?[0]?["text"]?["content"]?.text == "Se revisa el restore.")
        #expect(cuerpo["properties"]?["Temas"]?["multi_select"]?[0]?["name"]?.text == "backups")
        #expect(cuerpo["properties"]?["Temas"]?["multi_select"]?[1]?["name"]?.text == "minio")
    }

    @Test("sin resumen, sus columnas se vacian para que Notion no conserve el anterior")
    func sinResumenVacia() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Resumen", type: "rich_text"),
            NotionProperty(name: "Temas", type: "multi_select"),
        ])
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "x"))
        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: .gmt)

        #expect(cuerpo["properties"]?["Resumen"]?["rich_text"]?.count == 0)
        #expect(cuerpo["properties"]?["Temas"]?["multi_select"]?.count == 0)
    }

    @Test("una base sin columna de temas guarda las etiquetas como texto")
    func etiquetasComoTexto() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Temas", type: "rich_text"),
        ])
        var mapeo = NotionMapping()
        mapeo[.tags] = "Temas"
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "x"), digest: resumen)

        let cuerpo = createPageBody(pagina, in: fuente, mapping: mapeo, timeZone: .gmt)

        #expect(cuerpo["properties"]?["Temas"]?["rich_text"]?[0]?["text"]?["content"]?.text == "backups, minio")
    }

    @Test("un resumen larguisimo se acota al limite de Notion en vez de tumbar la pagina")
    func resumenAcotado() {
        let largo = Digest(
            title: "Largo", summary: String(repeating: "a", count: notionTextLimit + 500), tags: [])
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Resumen", type: "rich_text"),
        ])
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "x"), digest: largo)

        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: .gmt)

        #expect(cuerpo["properties"]?["Resumen"]?["rich_text"]?[0]?["text"]?["content"]?.text?.count == notionTextLimit)
    }

    @Test("publicar una nota con resumen manda sus columnas y su bloque a Notion")
    func publicaConResumen() async throws {
        let creado = Mutex<JSONValue?>(nil)
        let cliente = NotionClient(
            dataSources: { [] },
            createPage: { body in
                creado.withLock { $0 = body }
                return NotionPageRef(id: "pg", url: nil)
            },
            updatePage: { _, _ in }, appendBlocks: { _, _ in }, childBlocks: { _ in [] },
            deleteBlock: { _ in }, findPage: { _, _ in nil })
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Resumen", type: "rich_text"),
            NotionProperty(name: "Temas", type: "multi_select"),
        ])
        let export = NotionExport(
            source: fuente, mapping: suggestedMapping(for: fuente),
            template: BodyTemplate([.summary, .transcript(.plain)]))
        let nota = Note(
            recording: grabacion(), transcript: Transcript(text: "Cuerpo"), digest: resumen)

        let pagina = try await publish(nota, as: export, using: cliente)

        #expect(pagina.id == "pg")
        let cuerpo = try #require(creado.withLock { $0 })
        #expect(cuerpo["properties"]?["Nombre"]?["title"]?[0]?["text"]?["content"]?.text == "Backups de cortes")
        #expect(cuerpo["properties"]?["Resumen"]?["rich_text"]?[0]?["text"]?["content"]?.text == "Se revisa el restore.")
        #expect(cuerpo["properties"]?["Temas"]?["multi_select"]?[0]?["name"]?.text == "backups")
        #expect(cuerpo["children"]?[0]?["paragraph"]?["rich_text"]?[0]?["text"]?["content"]?.text == "Se revisa el restore.")
    }

    @Test("los comandos /resumen y /etiquetas estan en el menu")
    func comandos() {
        #expect(templateBlock(forCommand: "/resumen") == .summary)
        #expect(templateBlock(forCommand: "/etiquetas") == .field(.tags))
        #expect(slashCommands(matching: "/res").map(\.command) == ["/resumen"])
    }
}
