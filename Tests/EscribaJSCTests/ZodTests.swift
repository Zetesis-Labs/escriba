import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaJSC

private let herramientas = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: ".build/herramientas")
private let esbuild = herramientas.appending(path: "esbuild-wasm-\(EsbuildTools.version)")
private let paqueteZod = herramientas.appending(path: "zod-\(ZodPackage.version).tgz")
private let disponibles = EsbuildTools.isInstalled(in: esbuild)
    && FileManager.default.fileExists(atPath: paqueteZod.path(percentEncoded: false))

private func temporal(_ nombre: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-\(nombre)-\(UUID().uuidString)")
}

private func zodDesempaquetado() throws -> URL {
    let destino = temporal("zod")
    try ZodPackage.unpack(try Data(contentsOf: paqueteZod), into: destino)
    return destino
}

private let receta = """
    import { z } from "zod"

    const Reunion = z.object({
      cliente: z.string().nullable(),
      tareas: z.array(z.string()).min(1),
    })

    export const receta = { nombre: "Con Zod", datos: Reunion }

    export async function flujo(audio: Audio, escriba: Escriba): Promise<void> {
      const nota = await escriba.transcribir(audio)
      const datos = await escriba.preguntar({ esquema: Reunion, entrada: nota.texto })
      escriba.log(`tareas: ${datos.tareas.join(", ")}`)
      try {
        await escriba.preguntar({ esquema: Reunion, entrada: "vacía" })
      } catch (e) {
        escriba.log(e.message)
      }
      await nota.guardar({ datos })
    }
    """

@Suite("Zod dentro de Escriba", .enabled(if: disponibles))
struct ZodTests {
    @Test("el paquete de npm se desempaqueta con lo justo: JavaScript y tipos, sin fuentes ni Zod 3")
    func desempaqueta() throws {
        let zod = try zodDesempaquetado()
        let existe = { (ruta: String) in FileManager.default.fileExists(atPath: zod.appending(path: ruta).path(percentEncoded: false)) }

        #expect(ZodPackage.isInstalled(in: zod))
        #expect(existe("index.js"))
        #expect(existe("index.d.ts"))
        #expect(existe("v4/classic/external.js"))
        #expect(existe("package.json"))
        #expect(!existe("src"))
        #expect(!existe("v3"))
        #expect(!existe("index.cjs"))
    }

    @Test("lo descargado que no es el paquete esperado no se instala")
    func huella() async throws {
        let destino = temporal("zod-roto")
        await #expect(throws: EsbuildToolsError.checksum("zod-\(ZodPackage.version).tgz")) {
            try await ZodPackage.install(into: destino) { _ in Data("no es zod".utf8) }
        }
        #expect(!ZodPackage.isInstalled(in: destino))
    }

    @Test("una receta que importa zod compila, carga y Zod valida de verdad lo que contesta el LLM")
    func compilaYValida() async throws {
        let zod = try zodDesempaquetado()
        let compilador = EsbuildCompiler(tools: esbuild, zod: zod)
        let archivos = ["recetas/zod/receta.ts": receta]

        guard case .compiled(let codigo, _) = try await compilador.toolchain.compile(archivos, "recetas/zod/receta.ts")
        else {
            Issue.record("no compila")
            return
        }
        #expect(await compilador.toolchain.inspect(codigo) == .valid(name: "Con Zod"))

        let registro = Registro()
        try await ejecutar(
            RecipePackage(key: "zod", source: codigo, fingerprint: "z"),
            puente(registro, ask: { pregunta, _ in
                pregunta.input == "vacía" ? #"{"cliente":null,"tareas":[]}"# : #"{"cliente":"Acme","tareas":["llamar"]}"#
            }))

        #expect(registro.values.contains("log tareas: llamar"))
        #expect(registro.values.contains { $0.hasPrefix("log la respuesta del LLM no casa con el esquema: tareas: ") })
        #expect(registro.values.last?.hasPrefix(#"guarda {"cliente":"Acme","tareas":["llamar"]} según {"#) == true)
        #expect(registro.values.last?.contains(#""tareas":{"minItems":1,"type":"array""#) == true)
        #expect(registro.values.contains {
            $0.hasPrefix("pregunta hola con ") && $0.contains(#""tareas":{"minItems":1,"type":"array""#)
        })
    }

    @Test("sin Zod instalado ni copia administrada el diagnóstico pide instalar dependencias")
    func sinZod() async throws {
        let compilador = EsbuildCompiler(tools: esbuild)

        guard case .failed(let errores) = try await compilador.toolchain.compile(
            ["recetas/zod/receta.ts": receta], "recetas/zod/receta.ts")
        else {
            Issue.record("no debía compilar")
            return
        }
        #expect(errores.first?.text.contains("instala sus dependencias npm") == true)
    }

    @Test("los tipos de Zod se copian al proyecto una vez por versión")
    func tipos() throws {
        let zod = try zodDesempaquetado()
        let proyecto = temporal("proyecto")
        try FileManager.default.createDirectory(at: proyecto, withIntermediateDirectories: true)

        #expect(try ZodPackage.installTypes(from: zod, intoProject: proyecto))
        #expect(try !ZodPackage.installTypes(from: zod, intoProject: proyecto))

        let tipos = proyecto.appending(path: ZodPackage.projectFolder)
        #expect(FileManager.default.fileExists(atPath: tipos.appending(path: "index.d.ts").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: tipos.appending(path: "v4/core/schemas.d.ts").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: tipos.appending(path: "index.js").path(percentEncoded: false)))
    }
}
