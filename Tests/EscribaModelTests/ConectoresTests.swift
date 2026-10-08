import Foundation
import Testing
import EscribaCore
import EscribaNotion

@testable import EscribaModel

@MainActor private func ajustes() -> AppSettings {
    let defaults = UserDefaults(suiteName: "escriba-conectores-\(UUID().uuidString)")!
    return AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
}

private nonisolated func cliente(_ token: String) -> NotionClient {
    NotionClient(
        dataSources: { [] }, createPage: { _ in NotionPageRef(id: "pg", url: nil) },
        updatePage: { _, _ in }, appendBlocks: { _, _ in }, childBlocks: { _ in [] },
        deleteBlock: { _ in }, findPage: { _, _ in nil })
}

@MainActor
@Suite("Lista de conectores")
struct ConectoresTests {
    @Test("se pueden añadir varios y cada uno recibe un nombre distinto")
    func varios() {
        let modelo = ConnectorsModel(settings: ajustes(), tokens: { _ in .inMemory() }, client: cliente)

        let primero = modelo.add()
        let segundo = modelo.add()
        let tercero = modelo.add()

        #expect(modelo.connectors.map(\.name) == ["Notion", "Notion 2", "Notion 3"])
        #expect(Set([primero.id, segundo.id, tercero.id]).count == 3)
        #expect(modelo.connectors.allSatisfy { !$0.isLive })
    }

    @Test("cada conector tiene su propio token y su propio editor")
    func editoresIndependientes() async {
        var llaveros: [UUID: TokenStore] = [:]
        let modelo = ConnectorsModel(
            settings: ajustes(),
            tokens: { id in
                MainActor.assumeIsolated {
                    if let store = llaveros[id] { return store }
                    let store = TokenStore.inMemory()
                    llaveros[id] = store
                    return store
                }
            },
            client: cliente)
        let uno = modelo.add()
        let dos = modelo.add()

        modelo.editor(for: uno.id).token = "ntn_uno"
        modelo.editor(for: dos.id).token = "ntn_dos"

        #expect(modelo.editor(for: uno.id).token == "ntn_uno")
        #expect(modelo.editor(for: dos.id).token == "ntn_dos")
        #expect(modelo.editor(for: uno.id) === modelo.editor(for: uno.id))
    }

    @Test("quitar un conector borra su token y su configuracion")
    func quitar() {
        let llavero = TokenStore.inMemory("ntn_viejo")
        let ajustes = ajustes()
        let modelo = ConnectorsModel(settings: ajustes, tokens: { _ in llavero }, client: cliente)
        let conector = modelo.add()
        _ = modelo.editor(for: conector.id)

        modelo.remove(conector.id)

        #expect(modelo.connectors.isEmpty)
        #expect(llavero.read() == nil)
        #expect(ajustes.connector(conector.id) == nil)
    }

    @Test("quitar un conector lo quita de lo que publican las recetas de formulario, para que no fallen")
    func quitarDeLasRecetas() {
        let ajustes = ajustes()
        let modelo = ConnectorsModel(settings: ajustes, tokens: { _ in .inMemory() }, client: cliente)
        let uno = modelo.add()
        let otro = modelo.add()
        let receta = ajustes.recipeBook.forms[0].key
        ajustes.recipeBook.setValues(#"{"conectores":["\#(uno.key)","\#(otro.key)"]}"#, for: receta)

        modelo.remove(uno.id)

        #expect(ajustes.recipeBook.values[receta] == #"{"conectores":["\#(otro.key)"]}"#)
    }

    @Test("los conectores se guardan y vuelven con sus ajustes")
    func persistencia() {
        let defaults = UserDefaults(suiteName: "escriba-conectores-persist-\(UUID().uuidString)")!
        let antes = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
        var conector = Connector(name: "Trabajo", enabled: true)
        conector.notion = NotionExport(
            source: NotionDataSource(
                id: "ds", databaseTitle: "D", title: "D",
                properties: [NotionProperty(name: "Nombre", type: "title")]),
            columns: ["Nombre": "{{titulo}}"], body: "{{transcripcion-tiempos}}")
        antes.connectors = [conector]

        let despues = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)

        #expect(despues.connectors == [conector])
        #expect(despues.liveConnectors.map(\.name) == ["Trabajo"])
    }

    @Test("el editor cambia el cuerpo de la pagina y solo se guarda al pulsar Guardar")
    func cuerpoDesdeElEditor() {
        let ajustes = ajustes()
        let modelo = ConnectorsModel(settings: ajustes, tokens: { _ in .inMemory() }, client: cliente)
        let conector = modelo.add()
        let editor = modelo.editor(for: conector.id)
        editor.choose(
            NotionDataSource(
                id: "ds", databaseTitle: "D", title: "D",
                properties: [NotionProperty(name: "Nombre", type: "title")]))

        editor.body = "{{audio}}\nNotas\n{{transcripcion}}"
        #expect(ajustes.connector(conector.id)?.notion == nil)
        editor.save()

        #expect(ajustes.connector(conector.id)?.notion?.body == "{{audio}}\nNotas\n{{transcripcion}}")
        #expect(ajustes.connector(conector.id)?.notion?.needsAudio == true)
    }

    @Test("solo publican los conectores activados y listos")
    func vivos() {
        let ajustes = ajustes()
        let listo = NotionExport(
            source: NotionDataSource(
                id: "ds", databaseTitle: "D", title: "D",
                properties: [NotionProperty(name: "Nombre", type: "title")]),
            columns: ["Nombre": "{{titulo}}"])
        ajustes.connectors = [
            Connector(name: "apagado", enabled: false, notion: listo),
            Connector(name: "sin base", enabled: true, notion: nil),
            Connector(name: "vivo", enabled: true, notion: listo),
        ]

        #expect(ajustes.liveConnectors.map(\.name) == ["vivo"])
    }
}
