import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let deFormulario = RecipePackage(key: "por-defecto", source: "/* formulario */", fingerprint: "form123")

private let ajustes = DefaultRecipeSettings(
    stt: "whisper", language: "es", detectSpeakers: false, speakerCount: nil, summarize: false, llm: "apple",
    prompt: nil, connectors: [])

private func instalada(_ key: String, _ name: String) -> InstalledRecipe {
    InstalledRecipe(key: key, name: name, source: "/* \(key) */", fingerprint: "f-\(key)", installedAt: Date())
}

private func objetivo(_ key: String, parametros: DefaultRecipeSettings? = nil) -> RecipeTarget {
    RecipeTarget(
        key: key, name: key.capitalized, kind: parametros == nil ? .code : .form,
        package: RecipePackage(key: key, source: "", fingerprint: "f-\(key)"), parameters: parametros)
}

private let transcribeYGuarda: @Sendable (RecipeBridge) async throws -> Void = { escriba in
    _ = try await escriba.transcribe(RecipeTranscription())
    try await escriba.save()
}

private func pipeline(
    _ recordings: [Recording], shelf: RecipeShelf, runtime: RecipeRuntime, ledger: MemoryLedger = MemoryLedger(),
    listos: @escaping @Sendable (Recording) -> Bool = { _ in true }, eventos: Trace<PipelineEvent> = Trace()
) -> Pipeline {
    Pipeline(
        source: source(recordings), ledger: ledger.port,
        backend: backend { _ in Transcript(text: "hola") },
        sink: { note in URL(fileURLWithPath: "/salida/\(note.recording.key)") },
        readiness: { listos($0) ? .ready : .empty },
        recipe: Recipe(shelf: shelf, runtime: runtime, publishers: [:]),
        onEvent: { eventos.append($0) })
}

@Suite("Pipeline con la lista de recetas")
struct RecetasDisponiblesTests {
    @Test("cada nota usa la receta por defecto de ese momento, sin reconstruir el pipeline")
    func porDefectoDelMomento() async throws {
        let actual = Mutex("uno")
        let usadas = Trace<String>()
        let listas = Mutex<Set<String>>(["a"])
        let shelf = RecipeShelf(recipes: { [] }, target: { _ in objetivo(actual.withLock { $0 }) })
        let runtime = RecipeRuntime(name: "falso") { package, bridge in
            usadas.append(package.key)
            try await transcribeYGuarda(bridge)
        }
        let tuberia = pipeline(
            [recording("a"), recording("b", minute: 1)], shelf: shelf, runtime: runtime,
            listos: { recording in listas.withLock { $0.contains(recording.key) } })

        try await tuberia.runOnce()
        actual.withLock { $0 = "dos" }
        listas.withLock { $0.insert("b") }
        try await tuberia.runOnce()

        #expect(usadas.values == ["uno", "dos"])
    }

    @Test("si la receta por defecto no esta disponible, las notas esperan sin fallar y se avisa")
    func noDisponible() async throws {
        let ledger = MemoryLedger()
        let eventos = Trace<PipelineEvent>()
        let shelf = RecipeShelf(recipes: { [] }, target: { _ in throw RecipeError.defaultUnavailable("ideas") })
        let tuberia = pipeline(
            [recording("a"), recording("b", minute: 1)], shelf: shelf,
            runtime: RecipeRuntime(name: "falso") { _, bridge in try await transcribeYGuarda(bridge) },
            ledger: ledger, eventos: eventos)

        let outcome = try await tuberia.runOnce()

        #expect(outcome == PassOutcome(processed: 0, deferred: 2))
        #expect(ledger.failures.isEmpty)
        #expect(ledger.doneKeys.isEmpty)
        let avisos = eventos.values.compactMap { event in
            if case .recipeUnavailable(let reason) = event { reason } else { nil }
        }
        #expect(avisos == ["\(RecipeError.defaultUnavailable("ideas"))"])
        #expect(!eventos.values.contains { if case .transcribing = $0 { true } else { false } })
    }

    @Test("la receta recibe sus parametros y la traza lleva su clave y su nombre")
    func parametrosYTraza() async throws {
        let recibidos = Mutex<DefaultRecipeSettings?>(nil)
        let eventos = Trace<PipelineEvent>()
        let shelf = RecipeShelf(recipes: { [] }, target: { _ in objetivo("reuniones", parametros: ajustes) })
        let runtime = RecipeRuntime(name: "falso") { _, bridge in
            recibidos.withLock { $0 = bridge.parameters }
            try await transcribeYGuarda(bridge)
        }

        try await pipeline([recording("a")], shelf: shelf, runtime: runtime, eventos: eventos).runOnce()

        let traza = try #require(eventos.values.compactMap { event in
            if case .traced(_, let trace) = event { trace } else { nil }
        }.first)
        #expect(recibidos.withLock { $0 } == ajustes)
        #expect(traza.recipe == "reuniones")
        #expect(traza.name == "Reuniones")
        #expect(traza.headline == "Receta «Reuniones» · f-reuni")
    }
}

@Suite("Las recetas disponibles salen del libro y de los paquetes instalados")
struct EstanteDeRecetasTests {
    private func estante(
        _ book: RecipeBook, _ instaladas: [String: InstalledRecipe] = [:]
    ) -> RecipeShelf {
        recipeShelf(book: { book }, installed: { instaladas }, formPackage: deFormulario)
    }

    @Test("la por defecto de formulario ejecuta el codigo de formulario con sus parametros")
    func deFormularioPorDefecto() throws {
        let libro = RecipeBook(migrating: ajustes, key: "F1")

        let target = try estante(libro).target(nil)

        #expect(target == RecipeTarget(
            key: "F1", name: "Por defecto", kind: .form,
            package: RecipePackage(key: "F1", source: deFormulario.source, fingerprint: deFormulario.fingerprint),
            parameters: ajustes))
    }

    @Test("la por defecto de codigo ejecuta su paquete instalado, sin parametros")
    func deCodigoPorDefecto() throws {
        var libro = RecipeBook(migrating: ajustes, key: "F1")
        libro.makeDefault("ideas")

        let target = try estante(libro, ["ideas": instalada("ideas", "Ideas")]).target(nil)

        #expect(target == RecipeTarget(
            key: "ideas", name: "Ideas", kind: .code,
            package: RecipePackage(key: "ideas", source: "/* ideas */", fingerprint: "f-ideas"), parameters: nil))
    }

    @Test("una por defecto sin paquete no cae en otra: es un error que dice cual")
    func sinPaquete() {
        var libro = RecipeBook(migrating: ajustes, key: "F1")
        libro.makeDefault("ideas")

        #expect(throws: RecipeError.defaultUnavailable("ideas")) { try estante(libro).target(nil) }
    }

    @Test("otra receta se pide por clave o por nombre, de cualquiera de los dos tipos")
    func porNombre() throws {
        var libro = RecipeBook(migrating: ajustes, key: "F1")
        libro.add(key: "F2", name: "Reuniones", settings: ajustes)
        let shelf = estante(libro, ["ideas": instalada("ideas", "Ideas")])

        #expect(try shelf.target("reuniones").key == "F2")
        #expect(try shelf.target("IDEAS").key == "ideas")
        #expect(try shelf.target("F1").name == "Por defecto")
        #expect(throws: RecipeLookupError.missing(kind: .recipe, query: "nada")) { try shelf.target("nada") }
    }

    @Test("retocar los parametros para una vez cambia una de formulario y deja igual una de codigo")
    func retocar() {
        let deFormulario = objetivo("F1", parametros: ajustes)
        let deCodigo = objetivo("ideas")

        #expect(deFormulario.overriding(.standard).parameters == .standard)
        #expect(deFormulario.overriding(nil) == deFormulario)
        #expect(deCodigo.overriding(.standard) == deCodigo)
    }

    @Test("la lista lleva las de formulario y luego las de codigo, con su tipo")
    func lista() throws {
        let libro = RecipeBook(migrating: ajustes, key: "F1")
        let shelf = estante(libro, ["zeta": instalada("zeta", "Zeta"), "ideas": instalada("ideas", "Ideas")])

        #expect(try shelf.recipes() == [
            RecipeInfo(key: "F1", name: "Por defecto", kind: .form),
            RecipeInfo(key: "ideas", name: "Ideas", kind: .code),
            RecipeInfo(key: "zeta", name: "Zeta", kind: .code),
        ])
    }
}
