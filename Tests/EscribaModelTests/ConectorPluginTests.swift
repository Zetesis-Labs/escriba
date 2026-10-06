import Foundation
import Synchronization
import Testing
import EscribaPluginKit
import EscribaPlugins

@testable import EscribaModel

private let conector = UUID()

@MainActor private func ajustes() -> AppSettings {
    let defaults = UserDefaults(suiteName: "escriba-plugin-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
    settings.connectors = [Connector(id: conector, name: "OKF (plugin)", kind: .plugin, plugin: PluginExport(pluginID: "okf"))]
    return settings
}

private nonisolated let manifiesto = PluginManifest(id: "okf", name: "OKF (plugin)", version: "0.1", secrets: ["token"], folder: "folder")

private nonisolated final class PluginFalso: Sendable {
    let peticiones = Mutex<[PluginRequest]>([])
    let claves = Mutex<[[String: String]]>([])

    var runner: PluginRunner {
        { request, secrets in
            self.peticiones.withLock { $0.append(request) }
            self.claves.withLock { $0.append(secrets) }
            var config = request.config
            if request.action == "addDocument" { config["documents/0/name"] = .string("Nota") }
            let folder = request.config.text("folder")
            let hasToken = request.config["token"].string == secretMarker("token")
            return PluginResponse(
                form: PluginForm(
                    items: [.section("Carpeta", [.folder("folder")]), .note(hasToken ? "con token" : "sin token")],
                    problem: folder.isEmpty ? "Elige la carpeta." : nil),
                config: config, state: .object(["visto": .string(folder)]))
        }
    }

    var ultima: PluginRequest? { peticiones.withLock { $0.last } }
}

private nonisolated func esperar(_ condicion: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if await condicion() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite("Conector de plugin: editar con el formulario que describe el plugin")
struct ConectorPluginTests {
    private func modelo(_ falso: PluginFalso, _ settings: AppSettings = ajustes(), claves: TokenStore = .inMemory()) -> PluginConnectorModel {
        PluginConnectorModel(connector: conector, manifest: manifiesto, settings: settings, stores: ["token": claves], runner: falso.runner)
    }

    @Test("al abrir pide el formulario al plugin y la disponibilidad sale de el")
    func abre() async {
        let falso = PluginFalso()
        let modelo = modelo(falso)

        await esperar { modelo.form != nil }

        #expect(falso.ultima?.command == .form)
        #expect(modelo.readiness == "Elige la carpeta.")
        #expect(modelo.form?.items.count == 2)
        #expect(!modelo.isDirty)
    }

    @Test("elegir una carpeta pide el formulario al momento; escribir texto lo pide con retraso")
    func edita() async {
        let falso = PluginFalso()
        let modelo = modelo(falso)
        await esperar { modelo.form != nil }

        modelo.choose("/bundle", at: "folder")
        await esperar { modelo.readiness == nil }
        #expect(falso.ultima?.config.text("folder") == "/bundle")
        #expect(modelo.isDirty)

        let antes = falso.peticiones.withLock { $0.count }
        modelo.setValue("a", at: "documents/0/name")
        modelo.setValue("ab", at: "documents/0/name")
        #expect(falso.peticiones.withLock { $0.count } == antes)
        await esperar { falso.peticiones.withLock { $0.count } > antes }
        #expect(falso.peticiones.withLock { $0.count } == antes + 1)
        #expect(falso.ultima?.config.text("documents/0/name") == "ab")
        #expect(falso.ultima?.state["visto"].string == "/bundle")
    }

    @Test("una accion va al plugin y la configuracion que devuelve sustituye a la del borrador")
    func accion() async {
        let falso = PluginFalso()
        let modelo = modelo(falso)
        await esperar { modelo.form != nil }

        modelo.perform("addDocument")
        await esperar { modelo.value("documents/0/name") == "Nota" }

        #expect(falso.ultima?.command == .action)
        #expect(falso.ultima?.action == "addDocument")
    }

    @Test("la clave no viaja en la configuracion: el plugin ve un marcador y el host la guarda aparte")
    func clave() async {
        let falso = PluginFalso()
        let settings = ajustes()
        let claves = TokenStore.inMemory()
        let modelo = modelo(falso, settings, claves: claves)
        await esperar { modelo.form != nil }

        modelo.setSecret("ntn_1", field: "token")
        await esperar { falso.ultima?.config["token"].string == secretMarker("token") }
        #expect(falso.claves.withLock { $0.last } == ["token": "ntn_1"])
        #expect(modelo.value("token") == "")

        modelo.choose("/b", at: "folder")
        await esperar { modelo.readiness == nil }
        modelo.save()

        #expect(claves.read() == "ntn_1")
        #expect(settings.connector(conector)?.plugin?.config["token"] == .null)
        #expect(settings.connector(conector)?.plugin?.config.text("folder") == "/b")
        #expect(settings.connector(conector)?.plugin?.isUsable == true)
        #expect(!modelo.isDirty)
    }

    @Test("descartar vuelve a lo guardado y vuelve a pedir el formulario")
    func descarta() async {
        let falso = PluginFalso()
        let modelo = modelo(falso)
        await esperar { modelo.form != nil }
        modelo.choose("/b", at: "folder")
        await esperar { modelo.readiness == nil }

        modelo.discard()
        await esperar { modelo.readiness != nil }

        #expect(modelo.value("folder") == "")
        #expect(!modelo.isDirty)
    }
}
