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
private let conZod = EsbuildTools.isInstalled(in: esbuild)
    && FileManager.default.fileExists(atPath: paqueteZod.path(percentEncoded: false))

private let listas = RecipeLists(
    stts: [RecipeResolver(key: "whisper", name: "Whisper en este Mac", isLocal: true)],
    llms: [
        RecipeResolver(key: "apple", name: "Apple Intelligence", isLocal: true),
        RecipeResolver(key: "U2", name: "Groq", isLocal: false, model: "llama", baseURL: "https://api.groq.com"),
    ],
    connectors: [],
    recipes: [RecipeInfo(key: "F1", name: "Por defecto", kind: .form)])

private let esquemaFalso = """
    ({
      "~standard": {
        validate: (v) => (v.idioma === "xx"
          ? { issues: [{ path: ["idioma"], message: "no vale" }] }
          : { value: { idioma: "es", ...v } }),
        jsonSchema: { input: () => ({ type: "object", properties: { idioma: { type: "string", default: "es" } } }) },
      },
    })
    """

private func receta(formulario: String?, flujo: String = "escriba.log(JSON.stringify(escriba.parametros))") -> RecipePackage {
    RecipePackage(
        key: "prueba",
        source: "var __receta = { receta: { nombre: \"Prueba\" }, "
            + (formulario.map { "buildRecipeForm: \($0), " } ?? "")
            + "flujo: async (audio, escriba) => {\n\(flujo)\n} };",
        fingerprint: "prueba")
}

private func deCodigo(_ registro: Registro, valores: String? = nil) -> RecipeBridge {
    var bridge = puente(registro)
    bridge.values = valores
    bridge.stts = listas.stts
    bridge.llms = listas.llms
    bridge.connectors = listas.connectors
    bridge.recipes = listas.recipes
    return bridge
}

@Suite("Parámetros de una receta de código en JavaScriptCore")
struct ParametrosEnJavaScriptTests {
    @Test("sin buildRecipeForm no hay formulario y la receta de código sigue recibiendo parametros null")
    func sinFormulario() async throws {
        let registro = Registro()

        #expect(try recipeFormSchema(receta(formulario: nil), lists: listas) == nil)
        try await ejecutar(receta(formulario: nil), deCodigo(registro, valores: #"{"idioma":"en"}"#))

        #expect(registro.values == ["log null"])
    }

    @Test("buildRecipeForm recibe solo las listas y su esquema de entrada sale como JSON Schema")
    func esquema() throws {
        let formulario = """
            (listas) => ({
              "~standard": {
                validate: (v) => ({ value: v }),
                jsonSchema: { input: (o) => ({ target: o.target, claves: Object.keys(listas), llms: listas.llms.map((l) => l.clave), congeladas: Object.isFrozen(listas.llms) }) },
              },
            })
            """

        let texto = try #require(try recipeFormSchema(receta(formulario: formulario), lists: listas))

        #expect(try parseData(texto) == (try parseData(
            #"{"target":"draft-2020-12","claves":["stts","llms","conectores","recetas"],"llms":["apple","U2"],"congeladas":true}"#)))
    }

    @Test("al ejecutar, escriba.parametros son los valores guardados pasados por el esquema")
    func valores() async throws {
        let registro = Registro()

        try await ejecutar(receta(formulario: "() => \(esquemaFalso)"), deCodigo(registro, valores: #"{"otro":1}"#))
        try await ejecutar(receta(formulario: "() => \(esquemaFalso)"), deCodigo(registro))

        #expect(registro.values == [#"log {"idioma":"es","otro":1}"#, #"log {"idioma":"es"}"#])
    }

    @Test("un valor guardado que ya no casa hace fallar la ejecución y dice qué campo")
    func noCasa() async {
        await #expect(throws: RecipeError.failed(
            "Error: los parámetros de la receta no casan con el esquema: idioma: no vale")
        ) {
            try await ejecutar(
                receta(formulario: "() => \(esquemaFalso)"), deCodigo(Registro(), valores: #"{"idioma":"xx"}"#))
        }
    }

    @Test("si buildRecipeForm no devuelve un esquema de Zod, falla diciendo qué espera")
    func noEsZod() async {
        let mensaje = "\(recipeFormExport) tiene que devolver un esquema de Zod: z.object({ … })"

        #expect(throws: RecipeError.failed("TypeError: \(mensaje)")) {
            try recipeFormSchema(receta(formulario: "() => ({ idioma: 'es' })"), lists: listas)
        }
        await #expect(throws: RecipeError.failed("TypeError: \(mensaje)")) {
            try await ejecutar(receta(formulario: "() => ({ idioma: 'es' })"), deCodigo(Registro()))
        }
    }

    @Test("un buildRecipeForm que no es una función es un paquete que no vale")
    func noEsFuncion() async {
        let problema = "\(recipeFormExport) tiene que ser una función que devuelva un esquema de Zod"

        await #expect(throws: RecipeError.invalidPackage(problema)) {
            try await ejecutar(receta(formulario: "42"), deCodigo(Registro()))
        }
        #expect(throws: RecipeError.invalidPackage(problema)) {
            try recipeFormSchema(receta(formulario: "42"), lists: listas)
        }
    }

    @Test("un fallo dentro de buildRecipeForm se cuenta, y uno que no termina se corta por tiempo")
    func fallos() {
        #expect(throws: RecipeError.failed("Error: sin LLM (línea 1)")) {
            try recipeFormSchema(receta(formulario: "() => { throw new Error('sin LLM') }"), lists: listas)
        }
        #expect(throws: RecipeError.timedOut(0.2)) {
            try recipeFormSchema(receta(formulario: "() => { while (true) {} }"), lists: listas, timeLimit: 0.2)
        }
        #expect(throws: RecipeError.invalidPackage("SyntaxError: Unexpected end of script (línea 1)")) {
            try recipeFormSchema(RecipePackage(key: "rota", source: "var __receta = {", fingerprint: "r"), lists: listas)
        }
    }

    @Test("«Por defecto» declara su formulario con Zod: de serie hace lo de siempre y tiene los campos que lee la app")
    func porDefecto() throws {
        let conConectores = RecipeLists(
            stts: listas.stts, llms: listas.llms,
            connectors: [
                RecipeConnector(key: "K1", name: "Notion", kind: "notion"),
                RecipeConnector(key: "K2", name: "OKF", kind: "okf", isActive: false),
            ])

        let formulario = try recipeForm(
            from: try parseData(try #require(try recipeFormSchema(.defaultRecipe, lists: conConectores))))

        #expect(recipeFormDefaults(formulario) == formRecipeValues(.standard))
        #expect(formulario.fields.map(\.name) == ["stt", "idioma", "hablantes", "resumir", "llm", "prompt", "conectores"])
        #expect(formulario.fields.first { $0.name == "prompt" }?.kind == .text(lines: 6))
        #expect(formulario.fields.last?.kind == .choices([
            RecipeFormOption(value: "K1", label: "Notion"), RecipeFormOption(value: "K2", label: "OKF (apagado)"),
        ]))
        let ajustes = DefaultRecipeSettings(
            stt: "whisper", language: "en", detectSpeakers: true, speakerCount: 3, summarize: true, llm: "U2",
            prompt: "Breve", connectors: ["K2"])
        #expect(recipeFormValues(formulario, saved: formRecipeValues(ajustes)) == formRecipeValues(ajustes))
        #expect(RecipeBook(migrating: ajustes, key: "F1").reading(of: "F1") == FormRecipeReading(
            stt: "whisper", language: "en", summarize: true, llm: "U2", prompt: "Breve"))
    }

    @Test("con Zod de verdad: el formulario se construye con los LLM que hay y la ejecución rellena lo del script",
        .enabled(if: conZod))
    func conZodDeVerdad() async throws {
        let zod = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-zod-\(UUID().uuidString)")
        try ZodPackage.unpack(try Data(contentsOf: paqueteZod), into: zod)
        let fuente = """
            import { z } from "zod"

            export const receta = { nombre: "Con parámetros" }

            export function buildRecipeForm({ llms }: ListasDeEscriba) {
              return z.object({
                idioma: z.enum(["es", "en"]).nullable().default("es").meta({ title: "Idioma" }),
                hablantes: z
                  .object({
                    detectar: z.boolean().default(false).meta({ title: "Detectar hablantes" }),
                    cuantos: z.number().int().min(2).max(6).nullable().default(null).meta({ title: "Cuántos" }),
                  })
                  .prefault({})
                  .meta({ title: "Hablantes" }),
                llm: z
                  .union(llms.map((llm) => z.literal(llm.clave).meta({ title: llm.nombre })))
                  .default("apple")
                  .meta({ title: "LLM" }),
              })
            }

            type Parametros = z.output<ReturnType<typeof buildRecipeForm>>

            export async function flujo(audio: Audio, escriba: Escriba<Parametros>): Promise<void> {
              escriba.log(JSON.stringify(escriba.parametros))
            }
            """
        let compilador = EsbuildCompiler(tools: esbuild, zod: zod)
        guard case .compiled(let codigo, let mapa) = try await compilador.toolchain.compile(
            ["recetas/parametros/receta.ts": fuente], "recetas/parametros/receta.ts")
        else {
            Issue.record("no compila")
            return
        }
        let paquete = RecipePackage(key: "parametros", source: codigo, fingerprint: "p", sourceMap: mapa)

        let formulario = try recipeForm(from: try parseData(try #require(try recipeFormSchema(paquete, lists: listas))))

        #expect(formulario.fields.map(\.label) == ["Idioma", "Hablantes", "LLM"])
        #expect(formulario.fields.last?.kind == .choice([
            RecipeFormOption(value: "apple", label: "Apple Intelligence"), RecipeFormOption(value: "U2", label: "Groq"),
        ]))

        let registro = Registro()
        try await ejecutar(paquete, deCodigo(registro, valores: #"{"hablantes":{"cuantos":3},"llm":"U2"}"#))
        #expect(registro.values == [
            #"log {"idioma":"es","hablantes":{"detectar":false,"cuantos":3},"llm":"U2"}"#,
        ])

        await #expect(throws: RecipeError.self) {
            try await ejecutar(paquete, deCodigo(Registro(), valores: #"{"llm":"quitado"}"#))
        }
        do {
            try await ejecutar(paquete, deCodigo(Registro(), valores: #"{"llm":"quitado"}"#))
        } catch {
            #expect("\(error)".contains("los parámetros de la receta no casan con el esquema: llm: "))
        }
    }
}
