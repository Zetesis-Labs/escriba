import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

@Suite("Cuerpo de las peticiones a Notion")
struct PeticionTests {
    private let momento = Date(timeIntervalSince1970: 1_758_013_200)
    private let madrid = TimeZone(identifier: "Europe/Madrid")!

    private var fuente: NotionDataSource {
        NotionDataSource(
            id: "ds-1", databaseTitle: "Diario", title: "Notas",
            properties: [
                NotionProperty(name: "Nombre", type: "title"),
                NotionProperty(name: "Fecha", type: "date"),
                NotionProperty(name: "Hablantes", type: "multi_select"),
                NotionProperty(name: "Duración", type: "number"),
                NotionProperty(name: "Clave", type: "rich_text"),
                NotionProperty(name: "Origen", type: "url"),
            ])
    }

    private var pagina: NotionPage {
        notionPage(
            for: Recording(
                url: URL(fileURLWithPath: "/Notas/llamada.m4a"), startedAt: momento, key: "llamada"),
            transcript: Transcript(segments: [
                TranscriptSegment(start: 0, end: 12, speaker: "Ruben", text: "Hola."),
                TranscriptSegment(start: 12, end: 187, speaker: "Aritz", text: "Dime."),
            ]))
    }

    @Test("la pagina nace en la base elegida con cada dato en su propiedad")
    func propiedadesMapeadas() {
        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: madrid)

        #expect(cuerpo["parent"]?["data_source_id"] == .string("ds-1"))
        #expect(cuerpo["parent"]?["type"] == .string("data_source_id"))

        let props = cuerpo["properties"]
        #expect(props?["Nombre"]?["title"]?[0]?["text"]?["content"] == .string("Hola. Dime."))
        #expect(props?["Fecha"]?["date"]?["start"] == .string("2025-09-16T11:00:00+02:00"))
        #expect(props?["Hablantes"]?["multi_select"] == .array([
            .object(["name": .string("Ruben")]), .object(["name": .string("Aritz")]),
        ]))
        #expect(props?["Duración"]?["number"] == .number(187))
        #expect(props?["Clave"]?["rich_text"]?[0]?["text"]?["content"] == .string("llamada"))
        #expect(props?["Origen"]?["url"] == .string("file:///Notas/llamada.m4a"))
    }

    @Test("lo que el usuario deja sin mapear no viaja")
    func sinMapear() {
        var mapeo = suggestedMapping(for: fuente)
        mapeo[.duration] = nil
        mapeo[.source] = nil
        let props = createPageBody(pagina, in: fuente, mapping: mapeo, timeZone: madrid)["properties"]

        #expect(props?["Duración"] == nil)
        #expect(props?["Origen"] == nil)
        #expect(props?["Nombre"] != nil)
    }

    @Test("los datos de lista y numero se adaptan si la propiedad elegida es de texto")
    func adaptacionATexto() {
        let textual = NotionDataSource(
            id: "ds-2", databaseTitle: "Diario", title: "Notas",
            properties: [
                NotionProperty(name: "Nombre", type: "title"),
                NotionProperty(name: "Quien", type: "rich_text"),
                NotionProperty(name: "Cuanto", type: "rich_text"),
            ])
        var mapeo = suggestedMapping(for: textual)
        mapeo[.speakers] = "Quien"
        mapeo[.duration] = "Cuanto"
        let props = createPageBody(pagina, in: textual, mapping: mapeo, timeZone: madrid)["properties"]

        #expect(props?["Quien"]?["rich_text"]?[0]?["text"]?["content"] == .string("Ruben, Aritz"))
        #expect(props?["Cuanto"]?["rich_text"]?[0]?["text"]?["content"] == .string("03:07"))
    }

    @Test("el cuerpo de la pagina viaja como parrafos con la negrita del hablante")
    func bloquesDelCuerpo() {
        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: madrid)
        let primero = cuerpo["children"]?[0]

        #expect(primero?["object"] == .string("block"))
        #expect(primero?["type"] == .string("paragraph"))
        #expect(primero?["paragraph"]?["rich_text"]?[0]?["text"]?["content"] == .string("Ruben: "))
        #expect(primero?["paragraph"]?["rich_text"]?[0]?["annotations"]?["bold"] == .bool(true))
        #expect(primero?["paragraph"]?["rich_text"]?[1]?["text"]?["content"] == .string("Hola."))
    }

    @Test("una transcripcion larga deja la primera tanda en la pagina y el resto para despues")
    func tandas() {
        let largo = Transcript(segments: (0..<250).map {
            TranscriptSegment(
                start: Double($0), end: Double($0) + 1, speaker: "H\($0)", text: "turno \($0)")
        })
        let pagina = notionPage(
            for: Recording(url: URL(fileURLWithPath: "/a.m4a"), startedAt: momento, key: "a"),
            transcript: largo)
        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: madrid)

        #expect(cuerpo["children"]?.count == 100)
        #expect(notionBatches(pagina.blocks).count == 3)
        #expect(appendChildrenBody(notionBatches(pagina.blocks)[1])["children"]?.count == 100)
    }

    @Test("buscar por clave filtra por la propiedad que el usuario mapeo")
    func consultaPorClave() {
        var mapeo = suggestedMapping(for: fuente)
        #expect(findByKeyBody("llamada", mapping: mapeo)?["filter"] == .object([
            "property": .string("Clave"), "rich_text": .object(["equals": .string("llamada")]),
        ]))

        mapeo[.key] = nil
        #expect(findByKeyBody("llamada", mapping: mapeo) == nil)
    }

    @Test("el json que se envia es json valido")
    func serializacion() throws {
        let cuerpo = createPageBody(
            pagina, in: fuente, mapping: suggestedMapping(for: fuente), timeZone: madrid)
        let datos = try JSONEncoder().encode(cuerpo)
        let vuelta = try JSONSerialization.jsonObject(with: datos) as? [String: Any]

        #expect(vuelta?["parent"] != nil)
        #expect((vuelta?["children"] as? [Any])?.count == 2)
    }
}
