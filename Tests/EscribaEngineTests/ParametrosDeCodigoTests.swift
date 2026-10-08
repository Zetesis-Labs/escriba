import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let ajustes = DefaultRecipeSettings(
    stt: "whisper", language: "es", detectSpeakers: false, speakerCount: nil, summarize: false, llm: "apple",
    prompt: nil, connectors: [])

private let deFormulario = RecipePackage(key: "por-defecto", source: "/* formulario */", fingerprint: "form123")

private func instalada(_ key: String) -> InstalledRecipe {
    InstalledRecipe(key: key, name: key.capitalized, source: "/* \(key) */", fingerprint: "f-\(key)", installedAt: Date())
}

private func libro(valores: [String: String]) -> RecipeBook {
    var libro = RecipeBook(migrating: ajustes, key: "F1")
    for (clave, json) in valores { libro.setValues(json, for: clave) }
    return libro
}

private func estante(_ libro: RecipeBook) -> RecipeShelf {
    recipeShelf(
        book: { libro }, installed: { ["reparto": instalada("reparto"), "reuniones": instalada("reuniones")] },
        formPackage: deFormulario)
}

@Suite("Parámetros de las recetas de código: los valores de su formulario")
struct ParametrosDeCodigoTests {
    @Test("una receta de código lleva los valores de su formulario guardados en el libro; una de formulario, ninguno")
    func delLibro() throws {
        let shelf = estante(libro(valores: ["reparto": #"{"idioma":"en"}"#, "F1": #"{"x":1}"#]))

        #expect(try shelf.target("reparto").values == #"{"idioma":"en"}"#)
        #expect(try shelf.target("reuniones").values == nil)
        #expect(try shelf.target("F1").values == nil)
    }

    @Test("retocar los valores para una vez cambia una de código y deja igual una de formulario")
    func retocar() throws {
        let shelf = estante(libro(valores: ["reparto": #"{"idioma":"en"}"#]))
        let deCodigo = try shelf.target("reparto")
        let deFormulario = try shelf.target("F1")

        #expect(deCodigo.overriding(values: #"{"idioma":"es"}"#).values == #"{"idioma":"es"}"#)
        #expect(deCodigo.overriding(values: nil) == deCodigo)
        #expect(deFormulario.overriding(values: #"{"idioma":"es"}"#) == deFormulario)
    }

    @Test("los valores de una vez son solo de la receta de arriba: la que se llama con procesar usa los suyos guardados")
    func soloArriba() async throws {
        let shelf = estante(libro(valores: ["reparto": #"{"de":"libro"}"#, "reuniones": #"{"suyos":true}"#]))
        let vistos = Trace<String>()
        let recipe = Recipe(
            shelf: shelf,
            runtime: RecipeRuntime(name: "falso") { package, escriba in
                vistos.append("\(package.key) \(escriba.values ?? "nada")")
                if package.key == "reparto" { try await escriba.process("reuniones") }
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.save()
            },
            publishers: [:])

        let (resultado, _) = await runRecipe(
            try shelf.target("reparto").overriding(values: #"{"de":"una vez"}"#), of: recipe, on: recording("a"),
            backend: backend { _ in Transcript(text: "hola") }, enrich: nil, memory: nil,
            save: { _ in URL(fileURLWithPath: "/salida/a") })

        _ = try resultado.get()
        #expect(vistos.values == [#"reparto {"de":"una vez"}"#, #"reuniones {"suyos":true}"#])
    }

    @Test("las listas que recibe el formulario son las mismas que ve la receta al ejecutarse")
    func mismasListas() async throws {
        let shelf = estante(libro(valores: [:]))
        let vistas = Mutex<RecipeLists?>(nil)
        let recipe = Recipe(
            shelf: shelf,
            runtime: RecipeRuntime(name: "falso") { _, escriba in
                vistas.withLock { $0 = escriba.lists }
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.save()
            },
            publishers: [:],
            catalog: RecipeCatalog(
                stts: [RecipeResolver(key: "whisper", name: "Whisper", isLocal: true)],
                llms: [RecipeResolver(key: "apple", name: "Apple", isLocal: true)],
                connectors: [RecipeConnector(key: "K1", name: "Notion", kind: "notion", isActive: false)]))

        _ = await runRecipe(
            try shelf.target("reparto"), of: recipe, on: recording("a"), backend: backend { _ in Transcript(text: "hola") },
            enrich: nil, memory: nil, save: { _ in URL(fileURLWithPath: "/salida/a") })

        let listas = try recipe.lists()
        #expect(vistas.withLock { $0 } == listas)
        #expect(listas.recipes.map(\.key) == ["F1", "reparto", "reuniones"])
        #expect(listas.connectors.map(\.isActive) == [false])
    }
}
