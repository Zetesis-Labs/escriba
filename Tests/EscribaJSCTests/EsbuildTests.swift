import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaJSC

private let herramientas = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: ".build/herramientas/esbuild-wasm-\(EsbuildTools.version)")

private let disponibles = EsbuildTools.isInstalled(in: herramientas)

private let proyecto = [
    "comun/glosario.ts": """
        const reemplazos: Record<string, string> = { "escrivá": "Escriba" }
        export function corregir(texto: string): string {
          return Object.entries(reemplazos).reduce((t, [mal, bien]) => t.replaceAll(mal, bien), texto)
        }
        """,
    "comun/categorias.ts": """
        export type Categoria = "reunion" | "idea"
        export const CATEGORIAS: Categoria[] = ["reunion", "idea"]
        """,
    "recetas/general/receta.ts": """
        import { corregir } from "../../comun/glosario"
        import { CATEGORIAS, type Categoria } from "../../comun/categorias"
        import { titulo } from "./util"

        export const receta = { nombre: "General" }

        export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
          const nota = await escriba.transcribir(audio)
          const categoria: Categoria = CATEGORIAS[0]
          escriba.log(titulo(corregir(nota.texto)) + categoria)
          await nota.guardar()
        }
        """,
    "recetas/general/util.ts": "export const titulo = (texto: string): string => texto.toUpperCase()",
    "recetas/rota/receta.ts": """
        import { corregir } from "../../comun/glosaro"
        export const receta = { nombre: "Rota" }
        export async function flujo() { corregir("x") }
        """,
    "recetas/sintaxis/receta.ts": """
        export const receta = { nombre: "Mal escrita" }
        export async function flujo( {
          const x = 1
        }
        """,
    "recetas/rompe/receta.ts": """
        export const receta = { nombre: "Rompe" }

        export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
          const motivo: string = "a propósito"
          throw new Error(`se rompe ${motivo}`)
        }
        """,
    "recetas/npm/receta.ts": """
        import _ from "lodash"
        export const receta = { nombre: "Con npm" }
        export async function flujo() { _.noop() }
        """,
]

private func compilar(_ entrada: String, con compilador: EsbuildCompiler) async throws -> RecipeCompilation {
    try await compilador.toolchain.compile(proyecto, entrada)
}

@Suite("Compilar recetas con esbuild en JavaScriptCore", .enabled(if: disponibles))
struct EsbuildTests {
    @Test("compila un proyecto de varios ficheros con imports entre carpetas y el paquete carga")
    func compila() async throws {
        let compilador = EsbuildCompiler(tools: herramientas)

        guard case .compiled(let codigo, let mapa) = try await compilar("recetas/general/receta.ts", con: compilador) else {
            Issue.record("debia compilar")
            return
        }

        #expect(await compilador.toolchain.inspect(codigo) == .valid(name: "General"))
        #expect(!codigo.contains("Categoria ="))
        #expect(mapa.flatMap(SourceMap.init(json:)) != nil)
    }

    @Test("un error al ejecutar dice el fichero, la linea y la columna del TypeScript, no del paquete")
    func errorEnElTypeScript() async throws {
        guard case .compiled(let codigo, let mapa) = try await compilar(
            "recetas/rompe/receta.ts", con: EsbuildCompiler(tools: herramientas))
        else {
            Issue.record("debia compilar")
            return
        }
        let paquete = RecipePackage(key: "rompe", source: codigo, fingerprint: "x", sourceMap: mapa)
        let puente = RecipeBridge(
            audio: RecipeAudio(key: "a", name: "a", startedAt: Date()), connectors: [],
            transcribe: { _ in throw RecipeError.unavailable("no") }, summarize: { _ in throw RecipeError.unavailable("no") },
            save: {}, publish: { _ in }, log: { _, _ in })

        await #expect(throws: RecipeError.failed("Error: se rompe a propósito (recetas/rompe/receta.ts:5:13)")) {
            try await javaScriptCoreRuntime(timeLimit: 5).run(paquete, puente)
        }
    }

    @Test("un import roto dice fichero, linea y columna")
    func importRoto() async throws {
        let resultado = try await compilar("recetas/rota/receta.ts", con: EsbuildCompiler(tools: herramientas))

        #expect(resultado == .failed([RecipeBuildIssue(
            file: "recetas/rota/receta.ts", line: 1, column: 25, text: "no existe «../../comun/glosaro» en el proyecto")]))
    }

    @Test("un error de sintaxis dice donde esta")
    func sintaxis() async throws {
        guard case .failed(let errores) = try await compilar("recetas/sintaxis/receta.ts", con: EsbuildCompiler(tools: herramientas))
        else {
            Issue.record("no debia compilar")
            return
        }

        #expect(errores.first?.file == "recetas/sintaxis/receta.ts")
        #expect(errores.first?.line == 3)
    }

    @Test("un paquete npm no instalado da un diagnóstico")
    func npm() async throws {
        guard case .failed(let errores) = try await compilar("recetas/npm/receta.ts", con: EsbuildCompiler(tools: herramientas))
        else {
            Issue.record("no debia compilar")
            return
        }

        #expect(errores.first?.text.contains("instala sus dependencias npm") == true)
    }

    @Test("un paquete sin flujo no vale, y uno que no termina de cargar tampoco cuelga nada")
    func inspeccion() async throws {
        let compilador = EsbuildCompiler(tools: herramientas, inspectionLimit: 0.2)
        let inicio = ContinuousClock.now

        let sinFlujo = await compilador.toolchain.inspect("var __receta = { receta: { nombre: 'x' } }")
        let eterno = await compilador.toolchain.inspect("while (true) {}")

        #expect(sinFlujo == .invalid("falta la función flujo"))
        guard case .invalid(let motivo) = eterno else {
            Issue.record("un paquete que no termina no puede valer")
            return
        }
        #expect(motivo.contains("tarda más de"))
        #expect(ContinuousClock.now - inicio < .seconds(3))
    }

    @Test("esbuild se descarga de memoria tras un rato sin compilar, y vuelve a cargarse al pedirlo")
    func descarga() async throws {
        let compilador = EsbuildCompiler(tools: herramientas, idleAfter: 0.3)

        _ = try await compilar("recetas/general/receta.ts", con: compilador)
        #expect(await compilador.isLoaded)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await !compilador.isLoaded)

        #expect(try await compilar("recetas/general/receta.ts", con: compilador) != .failed([]))
        #expect(await compilador.isLoaded)
    }

    @Test("varias compilaciones a la vez comparten un solo esbuild")
    func aLaVez() async throws {
        let compilador = EsbuildCompiler(tools: herramientas)

        async let una = compilar("recetas/general/receta.ts", con: compilador)
        async let otra = compilar("recetas/rota/receta.ts", con: compilador)
        let (a, b) = try await (una, otra)

        guard case .compiled = a, case .failed = b else {
            Issue.record("una compila y la otra no: \(a), \(b)")
            return
        }
    }
}

@Suite("Herramientas de compilacion")
struct EsbuildToolsTests {
    @Test("en el CI, esbuild tiene que estar descargado: si falta, los tests de compilacion no se saltan en silencio")
    func enElCI() {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            #expect(disponibles, "ejecuta ./scripts/descargar-esbuild.sh antes de los tests")
        }
    }

    @Test("instalar comprueba lo descargado y no deja nada si no coincide", .enabled(if: disponibles))
    func instalar() async throws {
        let destino = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "esbuild-\(UUID().uuidString)")
        let roto = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "esbuild-\(UUID().uuidString)")

        try await EsbuildTools.install(into: destino) { url in
            try Data(contentsOf: herramientas.appending(path: url.lastPathComponent))
        }
        await #expect(throws: EsbuildToolsError.checksum("esbuild.wasm")) {
            try await EsbuildTools.install(into: roto) { _ in Data("no es esbuild".utf8) }
        }

        #expect(EsbuildTools.isInstalled(in: destino))
        #expect(!EsbuildTools.isInstalled(in: roto))
    }
}

@Suite("Dependencias npm de conectores", .enabled(if: disponibles))
struct ConectoresNPMTests {
    @Test("resuelve exports condicionales, subrutas, CommonJS y JSON transitivos")
    func dependenciasTransitivas() async throws {
        let compiler = EsbuildCompiler(tools: herramientas)
        let files = [
            "destino.ts": "import { value } from '@ejemplo/sdk/cliente'; export function run() { return value }",
            "node_modules/@ejemplo/sdk/package.json": "{\"exports\":{\"./cliente\":{\"import\":\"./client.js\"}}}",
            "node_modules/@ejemplo/sdk/client.js": "import value from 'valor'; export {value}",
            "node_modules/valor/package.json": "{\"main\":\"index.cjs\"}",
            "node_modules/valor/index.cjs": "module.exports = require('./data.json').value",
            "node_modules/valor/data.json": "{\"value\":42}"
        ]
        guard case .compiled(let source, _) = try await compiler.compileConnector(files: files, entry: "destino.ts") else {
            Issue.record("debe compilar los paquetes instalados")
            return
        }
        let runtime = try javaScriptCoreConnectorRuntime()
        let result = try await runtime.execute(ConnectorProgram(source: source, fingerprint: "npm"), "{}", ConnectorBridge { _ in "null" })
        #expect(result == "42")
    }

    @Test("una ruta relativa no puede escapar del proyecto")
    func fueraDelProyecto() async throws {
        let compiler = EsbuildCompiler(tools: herramientas)
        let files = ["destino.ts": "import '../../secret'; export function run() {}", "secret.ts": "export const token = 'no'" ]
        guard case .failed(let issues) = try await compiler.compileConnector(files: files, entry: "destino.ts") else {
            Issue.record("debía rechazar el escape")
            return
        }
        #expect(issues.contains { $0.text.contains("escapa") })
    }
    @Test("compila el SDK Notion instalado con su fallback criptográfico explícito")
    func sdkNPMReal() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "packages/conectores")
        guard let walker = FileManager.default.enumerator(at: root.appending(path: "node_modules"), includingPropertiesForKeys: [.isRegularFileKey]) else {
            Issue.record("instala npm de packages/conectores antes de validar el compilador")
            return
        }
        var files = ["destino.ts": "import {Client} from '@notionhq/client'; export async function run(r,h) { const sdk=new Client({fetch:h.fetch}); return await sdk.search({}) }" ]
        while let file = walker.nextObject() as? URL {
            guard ["js","cjs","mjs","json"].contains(file.pathExtension), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[String(file.path.dropFirst(root.path.count+1))] = try String(contentsOf:file,encoding:.utf8)
        }
        let compiler = EsbuildCompiler(tools: herramientas)
        let compilation = try await compiler.compileConnector(files: files, entry: "destino.ts")
        guard case .compiled(let source, _) = compilation else { Issue.record("SDK no compilado: \(compilation)"); return }
        let result = try await javaScriptCoreConnectorRuntime().execute(ConnectorProgram(source:source,fingerprint:"sdk-npm"), "{}", ConnectorBridge { _ in
            "{\"status\":200,\"headers\":{},\"body\":\"{\\\"results\\\":[]}\"}"
        })
        #expect(result == "{\"results\":[]}")
    }

    @Test("los imports calculados no se dejan para el runtime")
    func importDinamico() async throws {
        let compiler = EsbuildCompiler(tools: herramientas)
        let result = try await compiler.compileConnector(files: ["destino.ts":"export async function run(r) { return import(r.path) }"], entry: "destino.ts")
        guard case .failed = result else { Issue.record("debe diagnosticar un import que no puede empaquetar"); return }
    }

}
