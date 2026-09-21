import Foundation
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

    @Test("sin resumen, sus columnas no se escriben en vez de vaciarse con texto falso")
    func sinResumenNoEscribe() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Resumen", type: "rich_text"),
            NotionProperty(name: "Temas", type: "multi_select"),
        ])
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "x"))
        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: .gmt)

        #expect(cuerpo["properties"]?["Resumen"] == nil)
        #expect(cuerpo["properties"]?["Temas"] == nil)
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

    @Test("los comandos /resumen y /etiquetas estan en el menu")
    func comandos() {
        #expect(templateBlock(forCommand: "/resumen") == .summary)
        #expect(templateBlock(forCommand: "/etiquetas") == .field(.tags))
        #expect(slashCommands(matching: "/res").map(\.command) == ["/resumen"])
    }
}
