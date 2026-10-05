import Foundation
import Testing

@testable import EscribaNotion

@Suite("Eleccion de base y mapeo de propiedades")
struct MapeoTests {
    private func base(_ properties: [NotionProperty]) -> NotionDataSource {
        NotionDataSource(id: "ds-1", databaseTitle: "Diario", title: "Notas", properties: properties)
    }

    @Test("cada dato solo ofrece las propiedades de un tipo que admite")
    func propiedadesCompatibles() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Cuando", type: "date"),
            NotionProperty(name: "Quien", type: "multi_select"),
            NotionProperty(name: "Notas", type: "rich_text"),
            NotionProperty(name: "Segundos", type: "number"),
            NotionProperty(name: "Enlace", type: "url"),
            NotionProperty(name: "Hecho", type: "checkbox"),
        ])

        #expect(compatible(.title, in: fuente).map(\.name) == ["Nombre"])
        #expect(compatible(.date, in: fuente).map(\.name) == ["Cuando"])
        #expect(compatible(.speakers, in: fuente).map(\.name) == ["Quien", "Notas"])
        #expect(compatible(.duration, in: fuente).map(\.name) == ["Segundos", "Notas"])
        #expect(compatible(.source, in: fuente).map(\.name) == ["Enlace", "Notas"])
        #expect(compatible(.key, in: fuente).map(\.name) == ["Notas"])
        #expect(compatible(.title, in: base([])).isEmpty)
    }

    @Test("la sugerencia acierta por nombre aunque lleve tildes o mayusculas")
    func sugerenciaPorNombre() {
        let fuente = base([
            NotionProperty(name: "Título", type: "title"),
            NotionProperty(name: "Creado", type: "date"),
            NotionProperty(name: "Fecha de la grabación", type: "date"),
            NotionProperty(name: "Hablantes", type: "multi_select"),
            NotionProperty(name: "Duración", type: "number"),
            NotionProperty(name: "Clave", type: "rich_text"),
            NotionProperty(name: "Origen", type: "url"),
        ])
        let mapeo = suggestedMapping(for: fuente)

        #expect(mapeo[.title] == "Título")
        #expect(mapeo[.date] == "Fecha de la grabación")
        #expect(mapeo[.speakers] == "Hablantes")
        #expect(mapeo[.duration] == "Duración")
        #expect(mapeo[.key] == "Clave")
        #expect(mapeo[.source] == "Origen")
    }

    @Test("sin nombre reconocible cae a la primera propiedad compatible")
    func sugerenciaPorTipo() {
        let fuente = base([
            NotionProperty(name: "Asunto", type: "title"),
            NotionProperty(name: "Momento", type: "date"),
            NotionProperty(name: "Gente", type: "multi_select"),
        ])
        let mapeo = suggestedMapping(for: fuente)

        #expect(mapeo[.title] == "Asunto")
        #expect(mapeo[.date] == "Momento")
        #expect(mapeo[.speakers] == "Gente")
        #expect(mapeo[.duration] == nil)
    }

    @Test("un dato sin propiedad compatible se queda sin exportar")
    func datoSinSitio() {
        let mapeo = suggestedMapping(for: base([NotionProperty(name: "Nombre", type: "title")]))

        #expect(mapeo[.date] == nil)
        #expect(mapeo[.key] == nil)
        #expect(mapeo.assigned.count == 1)
    }

    @Test("una base sin propiedad de titulo no sirve para exportar")
    func baseSinTitulo() {
        let sinTitulo = base([NotionProperty(name: "Cuando", type: "date")])

        #expect(!NotionExport(source: sinTitulo, columns: suggestedColumns(for: sinTitulo)).isUsable)
        #expect(usabilityProblem(for: sinTitulo) == "La base «Notas» no tiene propiedad de título.")
    }

    @Test("mapear a mano respeta lo elegido y permite quitar un dato")
    func mapeoManual() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Creado", type: "date"),
            NotionProperty(name: "Grabado", type: "date"),
        ])
        var mapeo = suggestedMapping(for: fuente)

        mapeo[.date] = "Grabado"
        #expect(mapeo[.date] == "Grabado")

        mapeo[.date] = nil
        #expect(mapeo[.date] == nil)
        #expect(mapeo[.title] == "Nombre")
    }

    @Test("la sugerencia no le roba a otro dato la propiedad que lleva su nombre")
    func sinRobos() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Clave", type: "rich_text"),
            NotionProperty(name: "Libre", type: "rich_text"),
        ])
        let mapeo = suggestedMapping(for: fuente)

        #expect(mapeo[.key] == "Clave")
        #expect(mapeo[.speakers] == "Libre")
        #expect(mapeo[.source] == nil)
    }

    @Test("dos datos no pueden escribir en la misma propiedad")
    func propiedadUnica() {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Texto", type: "rich_text"),
            NotionProperty(name: "Otro", type: "rich_text"),
        ])
        var mapeo = suggestedMapping(for: fuente)
        #expect(mapeo[.speakers] != mapeo[.key])

        mapeo[.speakers] = "Texto"
        mapeo[.key] = "Texto"

        #expect(mapeo[.key] == "Texto")
        #expect(mapeo[.speakers] == nil)
    }

    @Test("el mapeo sobrevive a guardarse y releerse")
    func mapeoPersistente() throws {
        let fuente = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Creado", type: "date"),
        ])
        let original = suggestedMapping(for: fuente)
        let vuelta = try JSONDecoder().decode(
            NotionMapping.self, from: JSONEncoder().encode(original))

        #expect(vuelta == original)
    }

    @Test("un mapeo viejo se limpia de las propiedades que ya no existen")
    func mapeoDesfasado() {
        let antes = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Creado", type: "date"),
        ])
        let ahora = base([
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Cuando", type: "date"),
        ])
        let limpio = suggestedMapping(for: antes).pruned(to: ahora)

        #expect(limpio[.title] == "Nombre")
        #expect(limpio[.date] == nil)
    }
}
