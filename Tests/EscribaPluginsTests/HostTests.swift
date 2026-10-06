import Foundation
import Synchronization
import Testing
import EscribaCore
import EscribaPluginKit
import WAT

@testable import EscribaPlugins

private func carpeta() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "escriba-plugins-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func modulo(_ wat: String, http: @escaping HostHTTP = { _ in HostResponse(status: 200) }) throws -> PluginModule {
    let url = try carpeta().appending(path: "p.wasm")
    try Data(try wat2wasm(wat)).write(to: url)
    return try PluginModule(contentsOf: url, http: http)
}

private func escapado(_ json: String) -> String {
    json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// Un reactor minimo: recoge la peticion con take, opcionalmente hace una llamada al host y responde con un texto fijo.
private func wat(hostRequest: String?, respuesta: String) -> String {
    let llamada = hostRequest.map { peticion in
        """
        (local.set $n (call $call (i32.const 200000) (i32.const \(peticion.utf8.count))))
        (drop (call $take (i32.const 300000) (local.get $n)))
        """
    } ?? ""
    let datosPeticion = hostRequest.map { "(data (i32.const 200000) \"\(escapado($0))\")" } ?? ""
    return """
    (module
      (import "escriba" "call" (func $call (param i32 i32) (result i32)))
      (import "escriba" "take" (func $take (param i32 i32) (result i32)))
      (import "escriba" "respond" (func $respond (param i32 i32)))
      (memory (export "memory") 16)
      (data (i32.const 100) "\(escapado(respuesta))")
      \(datosPeticion)
      (func (export "_initialize"))
      (func (export "escriba_handle") (param $len i32) (result i32) (local $n i32)
        (drop (call $take (i32.const 100000) (local.get $len)))
        \(llamada)
        (call $respond (i32.const 100) (i32.const \(respuesta.utf8.count)))
        (i32.const 0)
      )
    )
    """
}

@Suite("Host de plugins WebAssembly")
struct HostTests {
    @Test("un plugin recibe la peticion y contesta por respond, y la instancia se reutiliza")
    func idaYVuelta() async throws {
        let plugin = try modulo(wat(hostRequest: nil, respuesta: #"{"ref":{"id":"nota-1","url":"https://x/1"}}"#))

        let primera = try await plugin.run(PluginRequest(command: .publish), permissions: .none)
        let segunda = try await plugin.run(PluginRequest(command: .publish), permissions: .none)

        #expect(primera.response.ref == PluginRef(id: "nota-1", url: "https://x/1"))
        #expect(segunda.response.ref == primera.response.ref)
        #expect(primera.elapsed < .seconds(2))
    }

    @Test("describe exige un manifiesto con el contrato de esta app")
    func describe() throws {
        let manifiesto = #"{"manifest":{"id":"x","name":"X","version":"1","contract":1,"secrets":[],"hosts":[]}}"#
        #expect(try modulo(wat(hostRequest: nil, respuesta: manifiesto)).describe().id == "x")

        let viejo = manifiesto.replacingOccurrences(of: #""contract":1"#, with: #""contract":7"#)
        #expect(throws: HostError.self) { try modulo(wat(hostRequest: nil, respuesta: viejo)).describe() }
        #expect(throws: HostError.self) { try modulo(wat(hostRequest: nil, respuesta: "{}")).describe() }
        #expect(throws: HostError.self) { try modulo(wat(hostRequest: nil, respuesta: "no json")).describe() }
    }

    @Test("un modulo que no es un plugin se rechaza")
    func noEsPlugin() throws {
        let plugin = try modulo(#"(module (memory (export "memory") 1) (func (export "_start")))"#)

        #expect(throws: HostError.self) { try plugin.describe() }
    }

    @Test("una peticion http del plugin pasa por el host, que pone la clave y filtra el dominio")
    func http() async throws {
        let vistas = Mutex<[HostRequest]>([])
        let peticion = #"{"op":"http","method":"POST","url":"https://api.notion.com/v1/pages","headers":{"Authorization":"Bearer {{secret:token}}"}}"#
        let plugin = try modulo(wat(hostRequest: peticion, respuesta: "{}")) { request in
            vistas.withLock { $0.append(request) }
            return HostResponse(status: 200, body: Data("ok".utf8))
        }

        _ = try await plugin.run(
            PluginRequest(command: .publish),
            permissions: PluginPermissions(hosts: ["api.notion.com"], secrets: ["token": "ntn_secreto"]))
        #expect(vistas.withLock { $0 }.map { $0.headers?["Authorization"] } == ["Bearer ntn_secreto"])

        _ = try await plugin.run(PluginRequest(command: .publish), permissions: PluginPermissions(hosts: ["example.com"]))
        #expect(vistas.withLock { $0 }.count == 1)
    }

    @Test("los ficheros del plugin viven solo dentro de su carpeta")
    func ficheros() async throws {
        let raiz = try carpeta()
        let escribe = #"{"op":"write","path":"notas/a.md","contents":"hola"}"#
        _ = try await modulo(wat(hostRequest: escribe, respuesta: "{}"))
            .run(PluginRequest(command: .publish), permissions: PluginPermissions(folder: raiz))
        #expect(try String(contentsOf: raiz.appending(path: "notas/a.md"), encoding: .utf8) == "hola")

        let fuera = #"{"op":"write","path":"../fuera.md","contents":"no"}"#
        _ = try await modulo(wat(hostRequest: fuera, respuesta: "{}"))
            .run(PluginRequest(command: .publish), permissions: PluginPermissions(folder: raiz))
        #expect(!FileManager.default.fileExists(atPath: raiz.deletingLastPathComponent().appending(path: "fuera.md").path))

        let sinCarpeta = #"{"op":"list"}"#
        let resultado = try await modulo(wat(hostRequest: sinCarpeta, respuesta: "{}"))
            .run(PluginRequest(command: .publish), permissions: .none)
        #expect(resultado.response == PluginResponse())
    }

    @Test("una respuesta grande viaja entera")
    func respuestaGrande() async throws {
        let grande = #"{"form":{"items":[],"problem":"\#(String(repeating: "a", count: 200_000))"}}"#
        let plugin = try modulo(wat(hostRequest: nil, respuesta: grande))

        let resultado = try await plugin.run(PluginRequest(command: .form), permissions: .none)

        #expect(resultado.response.form?.problem?.count == 200_000)
    }

    @Test("si el plugin se rompe, la siguiente llamada arranca una instancia nueva")
    func seRompe() async throws {
        let plugin = try modulo("""
            (module
              (import "escriba" "take" (func $take (param i32 i32) (result i32)))
              (import "escriba" "respond" (func $respond (param i32 i32)))
              (memory (export "memory") 1)
              (global $vez (mut i32) (i32.const 0))
              (data (i32.const 100) "{}")
              (func (export "_initialize"))
              (func (export "escriba_handle") (param $len i32) (result i32)
                (global.set $vez (i32.add (global.get $vez) (i32.const 1)))
                (if (i32.eq (global.get $vez) (i32.const 1)) (then (unreachable)))
                (call $respond (i32.const 100) (i32.const 2))
                (i32.const 0))
            )
            """)

        await #expect(throws: HostError.self) { try await plugin.run(PluginRequest(command: .form), permissions: .none) }
        let despues = try await plugin.run(PluginRequest(command: .form), permissions: .none)
        #expect(despues.response == PluginResponse())
    }
}

@Suite("Plugins de verdad", .enabled(if: ProcessInfo.processInfo.environment["ESCRIBA_PLUGIN_OKF"] != nil))
struct PluginsRealesTests {
    @Test("el plugin OKF se describe, da su formulario y publica una nota de ejemplo en una carpeta")
    func okf() async throws {
        let plugin = try PluginModule(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESCRIBA_PLUGIN_OKF"]!))
        let raiz = try carpeta()
        let reloj = ContinuousClock()

        var manifiesto: PluginManifest?
        let describir = try reloj.measure { manifiesto = try plugin.describe() }
        print("describe OKF por wasm (primera llamada): \(describir)")
        guard let manifiesto else { return }
        #expect(manifiesto.id == "okf")

        let binding = PluginBinding(
            module: plugin, manifest: manifiesto, config: .object(["folder": .string(raiz.path(percentEncoded: false))]), secrets: [:])
        var formulario: PluginResponse?
        let formar = try await reloj.measure { formulario = try await binding.run(PluginRequest(command: .form, config: binding.config)) }
        print("formulario OKF por wasm: \(formar)")
        #expect(formulario?.form?.problem == nil)
        #expect(formulario?.form?.items.contains { $0.kind == .section && $0.header == "Documentos" } == true)

        let sink = pluginSink(binding)
        var url = URL(fileURLWithPath: "/")
        let publicar = try await reloj.measure { url = try await sink(sampleNote(recordedAt: Date(timeIntervalSince1970: 1_791_219_600))) }
        print("publish OKF por wasm: \(publicar)")
        #expect(url.path(percentEncoded: false).hasPrefix(raiz.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "index.md").path))

        let otraVez = try await reloj.measure { _ = try await binding.run(PluginRequest(command: .form, config: binding.config)) }
        print("formulario OKF por wasm (repetido): \(otraVez)")
        #expect(otraVez < .seconds(1))
    }

    @Test("el plugin Notion se describe y sin token pide el token", .enabled(if: ProcessInfo.processInfo.environment["ESCRIBA_PLUGIN_NOTION"] != nil))
    func notion() async throws {
        let plugin = try PluginModule(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESCRIBA_PLUGIN_NOTION"]!))

        let manifiesto = try plugin.describe()
        #expect(manifiesto.secrets == ["token"])
        #expect(manifiesto.hosts == ["api.notion.com"])

        let binding = PluginBinding(module: plugin, manifest: manifiesto, config: .object([:]), secrets: [:])
        let respuesta = try await binding.run(PluginRequest(command: .form))
        #expect(respuesta.form?.problem == "Pega el token de tu integración de Notion.")
        #expect(respuesta.form?.items.first?.header == "Conexión con Notion")
    }
}
