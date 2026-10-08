import Foundation
import Testing
@testable import EscribaModel

@MainActor private func ajustes() -> AppSettings {
    let defaults = UserDefaults(suiteName: "escriba-conectores-\(UUID().uuidString)")!
    return AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
}

@MainActor @Suite("Cuentas y destinos del proyecto")
struct ConectoresTests {
    @Test("los ajustes antiguos conservan su configuración opaca hasta migrar")
    func legado() throws {
        let json = #"{"id":"ABADBABE-0000-0000-0000-000000000001","name":"Diario","kind":"custom","enabled":true,"custom":{"folder":"/tmp/notas","documents":[{"id":"doc","body":"{{texto}}"}]}}"#
        let connector = try JSONDecoder().decode(Connector.self, from: Data(json.utf8))
        #expect(connector.provider == "custom")
        #expect(connector.legacy)
        #expect(!connector.isLive)
        #expect(connector.configurationJSON.contains("{{texto}}"))
        #expect(connector.accountID == connector.id)
    }
}

@MainActor @Suite("Catálogo sin acceso implícito a credenciales")
struct ConnectorCatalogTests {
    private var services: ConnectorServices {
        ConnectorServices(run: { operation, _, config, _ in
            switch operation {
            case "manifest": return #"{"providers":[{"id":"custom","name":"Mi proveedor","capability":"folder","inputSchema":{"type":"object"}},{"id":"remote","name":"Remoto","capability":"http","origin":"https://example.com"}]}"#
            case "migrate": return "{\"configuration\":\(config),\"account\":{\"capability\":\"folder\",\"folder\":\"/tmp/notas\"}}"
            default: throw ConnectorCatalogError.invalid("Operación no esperada")
            }
        }, builtinFingerprint: "built-in")
    }

    @Test("inicializar migra los destinos y nunca lee el token")
    func migracionSinSecretos() async throws {
        let settings = ajustes()
        let id = UUID()
        settings.connectors = [Connector(id: id, name: "Diario", provider: "custom", accountID: id,
            enabled: true, configurationJSON: #"{"documents":[{"id":"old-doc"}]}"#, legacy: true)]
        let model = ConnectorsModel(settings: settings, tokens: { _ in
            TokenStore(read: { Issue.record("Lectura implícita del token"); return nil }, write: { _ in })
        }, services: services)
        try await model.initialize()
        #expect(model.accounts.first?.id == id)
        #expect(model.accounts.first?.folder == "/tmp/notas")
        #expect(model.connectors.first?.legacy == false)
        #expect(model.connectors.first?.configurationJSON.contains("old-doc") == true)
        #expect(model.connectors.first?.programFingerprint == "built-in")
        try await model.initialize()
        #expect(model.accounts.count == 1)
        #expect(settings.liveConnectors.count == 1)
    }

    @Test("retirar una fuente conserva su configuración para mantener publicaciones")
    func conservaHistorico() async throws {
        let settings = ajustes()
        let model = ConnectorsModel(settings: settings, tokens: { _ in .inMemory() }, services: services)
        try await model.initialize()
        let account = try model.addAccount(provider: "custom")
        let input = "{\"destinations\":[{\"id\":\"diario\",\"name\":\"Diario\",\"provider\":\"custom\",\"account\":\"\(account.id.uuidString)\",\"configuration\":{\"document\":\"original\"}}]}"
        try model.validateDestinations(inspectJSON: input, fingerprint: "v1")
        #expect(model.connectors.isEmpty)
        try model.installDestinations(inspectJSON: input, fingerprint: "v1")
        let identity = try #require(model.connectors.first).id
        try model.installDestinations(inspectJSON: #"{"destinations":[]}"#, fingerprint: "v2")
        #expect(model.connectors.first?.sourceMissing == true)
        #expect(model.connectors.first?.programFingerprint == "v1")
        #expect(settings.liveConnectors.isEmpty)
        try model.installDestinations(inspectJSON: input, fingerprint: "v3")
        #expect(model.connectors.first?.id == identity)
        #expect(model.connectors.first?.sourceMissing == false)
        #expect(model.connectors.first?.programFingerprint == "v3")
    }

    @Test("un catálogo inválido conserva la última versión instalada")
    func invalidoNoReemplaza() async throws {
        let model = ConnectorsModel(settings: ajustes(), services: services)
        try await model.initialize()
        let account = try model.addAccount(provider: "custom")
        let input = "{\"destinations\":[{\"id\":\"diario\",\"name\":\"Diario\",\"provider\":\"custom\",\"account\":\"\(account.id.uuidString)\",\"configuration\":{}}]}"
        try model.installDestinations(inspectJSON: input, fingerprint: "v1")
        #expect(throws: (any Error).self) {
            try model.installDestinations(inspectJSON: #"{"destinations":[{"id":"mal"}]}"#, fingerprint: "v2")
        }
        #expect(model.connectors.first?.programFingerprint == "v1")
    }

    @Test("revocar una cuenta borra el token y conserva destinos desactivados")
    func revocar() async throws {
        let settings = ajustes()
        let token = TokenStore.inMemory("secreto")
        let model = ConnectorsModel(settings: settings, tokens: { _ in token }, services: services)
        try await model.initialize()
        let account = try model.addAccount(provider: "remote")
        settings.connectors = [Connector(name: "Diario", provider: "remote", accountID: account.id, enabled: true, programFingerprint: "v1")]
        #expect(settings.liveConnectors.count == 1)
        try model.removeAccount(account.id)
        #expect(token.read() == nil)
        #expect(settings.liveConnectors.isEmpty)
        #expect(model.connectors.count == 1)
        #expect(model.accounts.first?.enabled == false)
    }

    @Test("cuentas y destinos se conservan al reabrir ajustes")
    func persistencia() throws {
        let defaults = UserDefaults(suiteName: "connector-persistence-\(UUID().uuidString)")!
        let before = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
        let account = ConnectorAccount(name: "Cuenta", provider: "custom", capability: "folder", folder: "/tmp/notas")
        let destination = Connector(name: "Diario", provider: "custom", accountID: account.id, enabled: true, programFingerprint: "v1")
        before.connectorAccounts = [account]
        before.connectors = [destination]
        let after = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
        #expect(after.connectorAccounts == [account])
        #expect(after.connectors == [destination])
        #expect(after.liveConnectors.count == 1)
    }
}

@MainActor @Test("exportar un destino migrado al proyecto conserva su identidad sin duplicarlo")
func destinoMigradoEnProyecto() throws {
    let settings = ajustes()
    let account = ConnectorAccount(name: "Cuenta", provider: "custom", capability: "folder")
    settings.connectorAccounts = [account]
    settings.connectors = [Connector(id: account.id, name: "Migrado", provider: "custom", accountID: account.id,
        enabled: true, programFingerprint: "builtin")]
    let model = ConnectorsModel(settings: settings, services: ConnectorServices(run: { _, _, _, _ in "{}" }, builtinFingerprint: "builtin"))
    let input = "{\"destinations\":[{\"id\":\"\(account.id.uuidString)\",\"name\":\"Proyecto\",\"provider\":\"custom\",\"account\":\"\(account.id.uuidString)\",\"configuration\":{}}]}"
    try model.installDestinations(inspectJSON: input, fingerprint: "project")
    #expect(model.connectors.count == 1)
    #expect(model.connectors.first?.id == account.id)
    #expect(model.connectors.first?.key == account.id.uuidString)
    #expect(model.connectors.first?.programFingerprint == "project")
}

@MainActor @Test("un legado incompleto no bloquea las cuentas ni la migración de otros destinos")
func migracionIncompletaVisible() async throws {
    let settings = ajustes()
    let incomplete = UUID(), valid = UUID()
    settings.connectors = [
        Connector(id: incomplete, name: "Incompleto", provider: "custom", accountID: incomplete, configurationJSON: "{}", legacy: true),
        Connector(id: valid, name: "Completo", provider: "custom", accountID: valid, configurationJSON: #"{"ready":true}"#, legacy: true),
    ]
    let model = ConnectorsModel(settings: settings, services: ConnectorServices(run: { operation, _, config, _ in
        if operation == "manifest" { return #"{"providers":[{"id":"custom","name":"Custom","capability":"folder"}]}"# }
        guard config != "{}" else { throw ConnectorCatalogError.invalid("Falta configuración") }
        return #"{"configuration":{"ready":true},"account":{"capability":"folder","folder":"/tmp"}}"#
    }, builtinFingerprint: "builtin"))
    try await model.initialize()
    #expect(model.providers.count == 1)
    #expect(model.connectors.first?.configurationJSON == "{}")
    #expect(model.connectors.first?.legacy == true)
    #expect(model.connectors.first?.migrationProblem == "Falta configuración")
    #expect(model.connectors.last?.legacy == false)
    #expect(model.problem?.contains("Incompleto") == true)
    #expect(try model.addAccount(provider: "custom").provider == "custom")
}
