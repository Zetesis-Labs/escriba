import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

private func propiedades(_ columnas: [String: String], _ nota: Note = notaDe()) -> JSONValue? {
    createPageBody(paginaDe(nota, como: exportDe(columnas: columnas)), in: baseCompleta)["properties"]
}

private func texto(_ valor: JSONValue?) -> JSONValue? {
    valor?["rich_text"]?[0]?["text"]?["content"]
}

@Suite("Columnas y peticiones a Notion")
struct PeticionTests {
    @Test("borrar de Notion archiva la pagina: se puede restaurar desde su papelera")
    func archivar() {
        #expect(archivePageBody() == .object(["archived": .bool(true)]))
    }

    @Test("la base sugiere que va en cada columna segun su nombre y su tipo")
    func sugerencias() {
        #expect(suggestedColumns(for: baseCompleta) == [
            "Nombre": "{{titulo}}", "Fecha": "{{fecha-iso}}", "Hablantes": "{{hablantes}}",
            "Duración": "{{segundos}}", "Clave": "{{clave}}", "Origen": "{{audio}}",
            "Resumen": "{{resumen}}", "Temas": "{{etiquetas}}",
        ])
    }

    @Test("la pagina nace en la base elegida con cada columna rellena")
    func columnasSugeridas() {
        let cuerpo = createPageBody(paginaDe(), in: baseCompleta)
        let props = cuerpo["properties"]

        #expect(cuerpo["parent"]?["data_source_id"] == .string("ds-1"))
        #expect(cuerpo["parent"]?["type"] == .string("data_source_id"))
        #expect(props?["Nombre"]?["title"]?[0]?["text"]?["content"] == .string("Hola. Dime."))
        #expect(props?["Fecha"]?["date"]?["start"] == .string("2025-09-16T11:00:00+02:00"))
        #expect(props?["Hablantes"]?["multi_select"] == .array([
            .object(["name": .string("Ruben")]), .object(["name": .string("Aritz")]),
        ]))
        #expect(props?["Duración"]?["number"] == .number(187))
        #expect(texto(props?["Clave"]) == .string("llamada"))
        #expect(props?["Origen"]?["url"] == .string("file:///Notas/llamada.m4a"))
    }

    @Test("una columna vacia o que no esta en la base no viaja")
    func sinValor() {
        let props = propiedades(["Nombre": "{{titulo}}", "Duración": "  ", "Inventada": "{{clave}}"])

        #expect(props?["Duración"] == nil)
        #expect(props?["Inventada"] == nil)
        #expect(props?["Nombre"] != nil)
    }

    @Test("una columna de texto admite texto fijo y datos mezclados; listas y duracion se escriben como texto")
    func textoMezclado() {
        let props = propiedades(["Nombre": "Llamada con {{hablantes}}", "Clave": "{{duracion}} · {{clave}}"])

        #expect(props?["Nombre"]?["title"]?[0]?["text"]?["content"] == .string("Llamada con Ruben, Aritz"))
        #expect(texto(props?["Clave"]) == .string("03:07 · llamada"))
    }

    @Test("selección múltiple: un dato de lista va como opciones; un texto con comas se trocea")
    func multiple() {
        let props = propiedades(["Temas": "{{etiquetas}}", "Hablantes": "uno, dos ,, tres"], notaDe(digest: resumenDeCharla))

        #expect(props?["Temas"]?["multi_select"] == .array([
            .object(["name": .string("backups")]), .object(["name": .string("talos linux")]),
        ]))
        #expect(props?["Hablantes"]?["multi_select"]?.count == 3)
    }

    @Test("select, numero, url y fecha reciben su tipo; lo que no encaja se vacia o no viaja")
    func tipos() {
        let props = propiedades([
            "Estado": "Revisar", "Duración": "abc", "Origen": "", "Fecha": "el martes", "Hecho": "{{clave}}",
        ])

        #expect(props?["Estado"]?["select"]?["name"] == .string("Revisar"))
        #expect(props?["Duración"]?["number"] == .null)
        #expect(props?["Origen"] == nil)
        #expect(props?["Fecha"] == nil)
        #expect(props?["Hecho"] == nil)
    }

    @Test("sin resumen, sus columnas se vacian para que Notion no conserve el anterior")
    func vaciado() {
        let props = propiedades(["Resumen": "{{resumen}}", "Temas": "{{etiquetas}}", "Estado": "{{resumen}}"])

        #expect(props?["Resumen"]?["rich_text"] == .array([]))
        #expect(props?["Temas"]?["multi_select"] == .array([]))
        #expect(props?["Estado"]?["select"] == .null)
    }

    @Test("un resumen larguisimo se acota al limite de Notion en vez de tumbar la pagina")
    func limite() {
        let largo = Digest(title: "t", summary: String(repeating: "a", count: 5000), tags: [])

        let props = propiedades(["Resumen": "{{resumen}}"], notaDe(digest: largo))

        guard case .string(let contenido) = texto(props?["Resumen"]) else {
            Issue.record("sin resumen")
            return
        }
        #expect(contenido.count == notionTextLimit)
    }

    @Test("con resumen, la pagina se titula con el; sin el, con el arranque del texto")
    func titulo() {
        let con = propiedades(["Nombre": "{{titulo}}"], notaDe(digest: resumenDeCharla))
        let sin = propiedades(["Nombre": "{{titulo}}"], notaDe(Transcript(text: "Hola que tal")))

        #expect(con?["Nombre"]?["title"]?[0]?["text"]?["content"] == .string("Backups de cortes"))
        #expect(sin?["Nombre"]?["title"]?[0]?["text"]?["content"] == .string("Hola que tal"))
    }

    @Test("buscar por clave usa la columna de texto cuyo valor es la clave")
    func consultaPorClave() {
        let export = exportDe()
        #expect(export.keyColumn == "Clave")
        #expect(findByKeyBody("llamada", column: export.keyColumn)?["filter"] == .object([
            "property": .string("Clave"), "rich_text": .object(["equals": .string("llamada")]),
        ]))

        #expect(exportDe(columnas: ["Nombre": "{{titulo}}", "Clave": "id {{clave}}"]).keyColumn == nil)
        #expect(findByKeyBody("llamada", column: nil) == nil)
    }

    @Test("sin nada en la columna de titulo la exportacion no vale")
    func tituloObligatorio() {
        #expect(exportDe().isUsable)
        #expect(!exportDe(columnas: ["Nombre": " ", "Clave": "{{clave}}"]).isUsable)
        #expect(notionProblem(exportDe(columnas: ["Clave": "{{clave}}"])) == "Escribe qué va en «Nombre», la columna del título.")
    }

    @Test("al refrescar la base se sugieren las columnas nuevas sin pisar lo elegido ni lo vaciado a proposito")
    func refresco() {
        let elegidas = ["Nombre": "Nota: {{titulo}}", "Cuando": "{{fecha-iso}}", "Clave": ""]
        let ahora = NotionDataSource(
            id: "ds", databaseTitle: "D", title: "D",
            properties: [
                NotionProperty(name: "Nombre", type: "title"), NotionProperty(name: "Clave", type: "rich_text"),
                NotionProperty(name: "Hablantes", type: "multi_select"),
            ])

        #expect(refreshedColumns(elegidas, for: ahora) == [
            "Nombre": "Nota: {{titulo}}", "Clave": "", "Hablantes": "{{hablantes}}",
        ])
        #expect(writableProperties(of: baseCompleta).map(\.name).contains("Hecho") == false)
        #expect(writableProperties(of: baseCompleta).first?.name == "Nombre")
    }

    @Test("una exportacion guardada con el mapeo y la plantilla de antes se lee como columnas y cuerpo")
    func formaAnterior() throws {
        let vieja = """
            {"source":{"id":"ds-1","databaseTitle":"Diario","title":"Notas","properties":[
                {"name":"Nombre","type":"title"},{"name":"Duración","type":"rich_text"},{"name":"Origen","type":"url"}]},
             "mapping":{"byField":{"title":"Nombre","duration":"Duración","source":"Origen"}},
             "template":{"blocks":[{"heading":{"_0":"Datos"}},{"field":{"_0":"speakers"}},{"audio":{}},
                                   {"transcript":{"_0":"timestamps"}}]}}
            """

        let export = try JSONDecoder().decode(NotionExport.self, from: Data(vieja.utf8))

        #expect(export.columns == ["Nombre": "{{titulo}}", "Duración": "{{duracion}}", "Origen": "{{audio}}"])
        #expect(export.body == "# Datos\n\n**Hablantes:** {{hablantes}}\n\n{{audio}}\n\n{{transcripcion-tiempos}}")
        let vuelta = try JSONDecoder().decode(NotionExport.self, from: JSONEncoder().encode(export))
        #expect(vuelta == export)
    }

    @Test("una transcripcion larga deja la primera tanda en la pagina y el resto para despues")
    func tandas() {
        let largo = Transcript(segments: (0..<250).map {
            TranscriptSegment(start: Double($0), end: Double($0) + 1, speaker: "H\($0)", text: "turno \($0)")
        })
        let pagina = paginaDe(notaDe(largo))

        #expect(createPageBody(pagina, in: baseCompleta)["children"]?.count == 100)
        #expect(notionBatches(pagina.blocks).count == 3)
        #expect(appendChildrenBody(notionBatches(pagina.blocks)[1])["children"]?.count == 100)
    }

    @Test("actualizar manda solo las propiedades; el cuerpo se reescribe aparte")
    func actualizar() {
        let cuerpo = updatePageBody(paginaDe())

        #expect(cuerpo["properties"]?["Nombre"] != nil)
        #expect(cuerpo["children"] == nil)
    }

    @Test("el json que se envia es json valido")
    func serializacion() throws {
        let datos = try JSONEncoder().encode(createPageBody(paginaDe(), in: baseCompleta))
        let vuelta = try JSONSerialization.jsonObject(with: datos) as? [String: Any]

        #expect(vuelta?["parent"] != nil)
        #expect((vuelta?["children"] as? [Any])?.count == 2)
    }
}
