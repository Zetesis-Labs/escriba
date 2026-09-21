import Foundation
import Testing
import EscribaNotion

@testable import EscribaModel

@MainActor private func ajustes() -> AppSettings {
    let defaults = UserDefaults(suiteName: "escriba-notion-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
    settings.connectors = [Connector(id: conector, name: "Notion")]
    return settings
}

private let conector = UUID()

private nonisolated func notas() -> NotionDataSource {
    NotionDataSource(
        id: "ds-1", databaseTitle: "Diario", title: "Notas",
        properties: [
            NotionProperty(name: "Nombre", type: "title"),
            NotionProperty(name: "Fecha", type: "date"),
            NotionProperty(name: "Clave", type: "rich_text"),
        ])
}

private nonisolated func llamadas() -> NotionDataSource {
    NotionDataSource(
        id: "ds-2", databaseTitle: "Llamadas", title: "Llamadas",
        properties: [NotionProperty(name: "Asunto", type: "title")])
}

private nonisolated func client(
    _ answer: @escaping @Sendable () async throws(NotionError) -> [NotionDataSource]
) -> @Sendable (String) -> NotionClient {
    { _ in
        NotionClient(
            dataSources: answer,
            createPage: { _ in NotionPageRef(id: "pg", url: nil) },
            updatePage: { _, _ in }, appendBlocks: { _, _ in }, childBlocks: { _ in [] },
            deleteBlock: { _ in }, findPage: { _, _ in nil })
    }
}

@MainActor
@Suite("Conectar Notion desde los ajustes")
struct NotionModelTests {
    @Test("conectar trae las bases a las que la integracion tiene acceso")
    func conecta() async {
        let modelo = NotionModel(
            connector: conector, settings: ajustes(), tokens: .inMemory(), client: client { [notas(), llamadas()] })
        modelo.token = "  ntn_secreto  "

        await modelo.connect()

        #expect(modelo.sources.map(\.id) == ["ds-1", "ds-2"])
        #expect(modelo.token == "ntn_secreto")
        #expect(modelo.phase == .idle)
    }

    @Test("conectar comprueba el token pero no lo guarda: se guarda al pulsar Guardar")
    func tokenGuardado() async {
        let llavero = TokenStore.inMemory()
        let modelo = NotionModel(connector: conector, settings: ajustes(), tokens: llavero, client: client { [notas()] })
        modelo.token = "ntn_bueno"

        await modelo.connect()
        #expect(llavero.read() == nil)
        #expect(modelo.isDirty)

        modelo.save()
        #expect(llavero.read() == "ntn_bueno")
        #expect(!modelo.isDirty)
    }

    @Test("los cambios quedan en borrador hasta Guardar, y Descartar vuelve a lo guardado")
    func borrador() {
        let ajustes = ajustes()
        let modelo = NotionModel(connector: conector, settings: ajustes, tokens: .inMemory(), client: client { [] })

        modelo.name = "Diario"
        modelo.choose(notas())
        #expect(modelo.name == "Diario")
        #expect(modelo.selected?.id == "ds-1")
        #expect(ajustes.connector(conector)?.name == "Notion")
        #expect(ajustes.connector(conector)?.notion == nil)
        #expect(modelo.isDirty)

        modelo.discard()
        #expect(modelo.name == "Notion")
        #expect(modelo.selected == nil)
        #expect(!modelo.isDirty)

        modelo.name = "Diario"
        modelo.save()
        #expect(ajustes.connector(conector)?.name == "Diario")
        #expect(!modelo.isDirty)
    }

    @Test("un token rechazado deja el motivo a la vista y no guarda nada")
    func tokenRechazado() async {
        let llavero = TokenStore.inMemory()
        let modelo = NotionModel(
            connector: conector, settings: ajustes(), tokens: llavero,
            client: client { () throws(NotionError) in throw NotionError.unauthorized })
        modelo.token = "ntn_malo"

        await modelo.connect()

        #expect(modelo.phase.problem == "Notion rechaza el token. Revísalo en Ajustes.")
        #expect(llavero.read() == nil)
        #expect(!modelo.isConnected)
    }

    @Test("una integracion sin bases compartidas lo dice en vez de quedarse muda")
    func sinBases() async {
        let modelo = NotionModel(connector: conector, settings: ajustes(), tokens: .inMemory(), client: client { [] })
        modelo.token = "ntn"

        await modelo.connect()

        #expect(modelo.phase.problem?.contains("Compártele una desde Notion") == true)
    }

    @Test("elegir base propone el mapeo y deja la exportacion lista")
    func eligeBase() async {
        let ajustes = ajustes()
        let modelo = NotionModel(
            connector: conector, settings: ajustes, tokens: .inMemory("ntn"), client: client { [notas()] })

        modelo.choose(notas())
        modelo.save()

        #expect(modelo.selected?.id == "ds-1")
        #expect(modelo.property(for: .title) == "Nombre")
        #expect(modelo.property(for: .key) == "Clave")
        #expect(modelo.readiness == nil)
        #expect(ajustes.connector(conector)?.isReady == true)
    }

    @Test("cambiar de base no arrastra el mapeo de la anterior")
    func cambiaBase() {
        let modelo = NotionModel(connector: conector, settings: ajustes(), tokens: .inMemory(), client: client { [] })

        modelo.choose(notas())
        modelo.choose(llamadas())

        #expect(modelo.property(for: .title) == "Asunto")
        #expect(modelo.property(for: .key) == nil)
    }

    @Test("el usuario puede quitar un dato del mapeo y se guarda")
    func mapeoManual() {
        let ajustes = ajustes()
        let modelo = NotionModel(connector: conector, settings: ajustes, tokens: .inMemory(), client: client { [] })
        modelo.choose(notas())

        modelo.assign(.date, to: nil)
        modelo.save()

        #expect(modelo.property(for: .date) == nil)
        #expect(ajustes.connector(conector)?.notion?.mapping[.date] == nil)
    }

    @Test("solo se ofrecen propiedades que admiten el dato")
    func opciones() {
        let modelo = NotionModel(connector: conector, settings: ajustes(), tokens: .inMemory(), client: client { [] })
        modelo.choose(notas())

        #expect(modelo.options(for: .date).map(\.name) == ["Fecha"])
        #expect(modelo.options(for: .duration).map(\.name) == ["Clave"])
        #expect(modelo.options(for: .title).map(\.name) == ["Nombre"])
    }

    @Test("sin token o sin base, la pantalla dice que falta")
    func readiness() {
        let modelo = NotionModel(connector: conector, settings: ajustes(), tokens: .inMemory(), client: client { [] })

        #expect(modelo.readiness == "Pega el token de tu integración de Notion.")
        modelo.token = "ntn"
        #expect(modelo.readiness == "Elige la base donde guardar.")
    }

    @Test("la publicacion automatica solo cuenta si la exportacion vale")
    func exportacionViva() {
        let ajustes = ajustes()
        let modelo = NotionModel(connector: conector, settings: ajustes, tokens: .inMemory(), client: client { [] })

        modelo.publishes = true
        modelo.save()
        #expect(ajustes.liveConnectors.isEmpty)

        modelo.choose(notas())
        modelo.save()
        #expect(ajustes.liveConnectors.first?.notion?.source.id == "ds-1")

        modelo.assign(.title, to: nil)
        modelo.save()
        #expect(ajustes.liveConnectors.isEmpty)
    }

    @Test("reconectar refresca las propiedades de la base elegida y limpia las que ya no estan")
    func refresco() async {
        let ajustes = ajustes()
        let modelo = NotionModel(connector: conector, settings: ajustes, tokens: .inMemory(), client: client {
            [NotionDataSource(
                id: "ds-1", databaseTitle: "Diario", title: "Notas",
                properties: [NotionProperty(name: "Nombre", type: "title")])]
        })
        modelo.choose(notas())
        modelo.token = "ntn"

        await modelo.connect()

        #expect(modelo.property(for: .title) == "Nombre")
        #expect(modelo.property(for: .key) == nil)
        #expect(modelo.selected?.properties.count == 1)
    }

    @Test("desconectar no guarda de rebote otros cambios del borrador")
    func desconectarNoArrastra() async {
        let ajustes = ajustes()
        let modelo = NotionModel(connector: conector, settings: ajustes, tokens: .inMemory("ntn"), client: client { [] })
        modelo.name = "Sin guardar"

        modelo.disconnect()

        #expect(ajustes.connector(conector)?.name == "Notion")
        #expect(ajustes.connector(conector)?.notion == nil)
        #expect(modelo.name == "Sin guardar")
        #expect(modelo.isDirty)
    }

    @Test("desconectar borra el token, la base y la publicacion automatica")
    func desconecta() async {
        let ajustes = ajustes()
        let llavero = TokenStore.inMemory()
        let modelo = NotionModel(connector: conector, settings: ajustes, tokens: llavero, client: client { [notas()] })
        modelo.token = "ntn"
        await modelo.connect()
        modelo.choose(notas())
        modelo.publishes = true

        modelo.disconnect()

        #expect(modelo.token.isEmpty)
        #expect(llavero.read() == nil)
        #expect(ajustes.connector(conector)?.notion == nil)
        #expect(ajustes.connector(conector)?.enabled == false)
        #expect(modelo.sources.isEmpty)
    }
}
