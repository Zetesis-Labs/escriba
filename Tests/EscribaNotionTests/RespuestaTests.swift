import Foundation
import Testing

@testable import EscribaNotion

@Suite("Lectura de las respuestas de Notion")
struct RespuestaTests {
    private func json(_ text: String) -> JSONValue {
        jsonValue(from: try! JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    @Test("de la busqueda salen las bases con sus propiedades y su tipo")
    func basesDeLaBusqueda() {
        let respuesta = json(
            """
            {"object":"list","results":[
              {"object":"data_source","id":"ds-1","name":"Notas",
               "database_parent":{"type":"database_id","database_id":"db-1"},
               "properties":{
                 "Nombre":{"id":"title","name":"Nombre","type":"title","title":{}},
                 "Fecha":{"id":"abc","name":"Fecha","type":"date","date":{}}}},
              {"object":"data_source","id":"ds-2","title":[{"plain_text":"Llamadas"}],
               "properties":{"Name":{"id":"title","name":"Name","type":"title","title":{}}}}
            ],"has_more":false,"next_cursor":null}
            """)
        let bases = parseDataSources(respuesta)

        #expect(bases.count == 2)
        #expect(bases[0].id == "ds-1")
        #expect(bases[0].title == "Notas")
        #expect(bases[0].properties.sorted { $0.name < $1.name } == [
            NotionProperty(name: "Fecha", type: "date"),
            NotionProperty(name: "Nombre", type: "title"),
        ])
        #expect(bases[1].title == "Llamadas")
    }

    @Test("lo que no es una base se ignora")
    func ruidoIgnorado() {
        let respuesta = json(
            """
            {"results":[{"object":"page","id":"p-1"},
                        {"object":"data_source","id":"ds-1","name":"Notas","properties":{}}]}
            """)

        #expect(parseDataSources(respuesta).map(\.id) == ["ds-1"])
        #expect(parseDataSources(json("{}")).isEmpty)
    }

    @Test("de la pagina creada sale su identificador y su enlace")
    func paginaCreada() {
        let respuesta = json(
            """
            {"object":"page","id":"pg-1","url":"https://www.notion.so/Hola-pg1"}
            """)

        #expect(parsePage(respuesta)?.id == "pg-1")
        #expect(parsePage(respuesta)?.url == URL(string: "https://www.notion.so/Hola-pg1"))
        #expect(parsePage(json("{\"object\":\"error\"}")) == nil)
    }

    @Test("de la consulta por clave sale la pagina que ya existe, o ninguna")
    func consultaPorClave() {
        #expect(parseFirstPage(json("{\"results\":[{\"id\":\"pg-9\",\"url\":\"https://n/9\"}]}"))?.id == "pg-9")
        #expect(parseFirstPage(json("{\"results\":[]}")) == nil)
    }

    @Test("el mensaje de error de la API llega entero a quien lo tiene que leer")
    func mensajeDeError() {
        let respuesta = json(
            """
            {"object":"error","status":400,"code":"validation_error",
             "message":"body failed validation: body.parent.data_source_id should be a valid uuid"}
            """)

        #expect(parseErrorMessage(respuesta) == "body failed validation: body.parent.data_source_id should be a valid uuid")
        #expect(parseErrorMessage(json("{}")) == nil)
    }

    @Test("el cursor de paginacion se sigue mientras haya mas")
    func cursor() {
        #expect(nextCursor(json("{\"has_more\":true,\"next_cursor\":\"c-2\"}")) == "c-2")
        #expect(nextCursor(json("{\"has_more\":false,\"next_cursor\":\"c-2\"}")) == nil)
        #expect(nextCursor(json("{}")) == nil)
    }
}
