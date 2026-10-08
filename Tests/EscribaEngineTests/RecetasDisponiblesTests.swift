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

private func objetivo(_ key: String, parametros: String? = nil) -> RecipeTarget {
    RecipeTarget(
        key: key, name: key.capitalized, kind: parametros == nil ? .code : .form,
        package: RecipePackage(key: key, source: "", fingerprint: "f-\(key)"), values: parametros)
}

private let transcribeYGuarda: @Sendable (RecipeBridge) async throws -> Void = { escriba in
    _ = try await escriba.transcribe(RecipeTranscription())
    try await escriba.save()
}

private func pipeline(
    _ recordings: [Recording], shelf: RecipeShelf, runtime: RecipeRuntime, ledger: MemoryLedger = MemoryLedger(),
    listos: @escaping @Sendable (Recording) -> Bool = { _ in true }, eventos: Trace<PipelineEvent> = Trace(),
    elegidas: [String: String] = [:]
) -> Pipeline {
    Pipeline(
        source: RecordingSource(
            name: "falsa", locations: [URL(fileURLWithPath: "/grabaciones")],
            chosenRecipe: { elegidas[$0.key] }
        ) { recordings },
        ledger: ledger.port,
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

    @Test("lo que entra con receta elegida se procesa con ella; lo demás, con la por defecto")
    func elegida() async throws {
        let usadas = Trace<String>()
        let shelf = RecipeShelf(recipes: { [] }, target: { objetivo($0 ?? "defecto") })
        let runtime = RecipeRuntime(name: "falso") { package, bridge in
            usadas.append("\(bridge.audio.key) \(package.key)")
            try await transcribeYGuarda(bridge)
        }

        try await pipeline(
            [recording("a"), recording("b", minute: 1)], shelf: shelf, runtime: runtime, elegidas: ["a": "reparto"]
        ).runOnce()

        #expect(usadas.values.sorted() == ["a reparto", "b defecto"])
    }

    @Test("si la receta elegida ya no está, falla esa grabación diciéndolo y las demás siguen")
    func elegidaQueYaNoEsta() async throws {
        let ledger = MemoryLedger()
        let eventos = Trace<PipelineEvent>()
        let shelf = RecipeShelf(recipes: { [] }, target: { query in
            guard let query else { return objetivo("defecto") }
            throw RecipeLookupError.missing(kind: .recipe, query: query)
        })
        let runtime = RecipeRuntime(name: "falso") { _, bridge in try await transcribeYGuarda(bridge) }

        let outcome = try await pipeline(
            [recording("a"), recording("b", minute: 1)], shelf: shelf, runtime: runtime, ledger: ledger,
            eventos: eventos, elegidas: ["a": "borrada"]
        ).runOnce()

        let motivo = "la receta elegida para esta grabación no está disponible: \(RecipeLookupError.missing(kind: .recipe, query: "borrada"))"
        #expect(outcome == PassOutcome(processed: 1, deferred: 0))
        #expect(ledger.doneKeys == ["b"])
        #expect(ledger.failures == ["a": motivo])
        #expect(!eventos.values.contains { if case .recipeUnavailable = $0 { true } else { false } })
    }

    @Test("si no se pueden leer las recetas, lo elegido espera como lo demás en vez de fallar")
    func elegidaSinRecetasLegibles() async throws {
        let ledger = MemoryLedger()
        let shelf = RecipeShelf(recipes: { [] }, target: { _ in throw FakeError.scanBroken })
        let runtime = RecipeRuntime(name: "falso") { _, bridge in try await transcribeYGuarda(bridge) }

        let outcome = try await pipeline(
            [recording("a"), recording("b", minute: 1)], shelf: shelf, runtime: runtime, ledger: ledger,
            elegidas: ["a": "reparto"]
        ).runOnce()

        #expect(outcome == PassOutcome(processed: 0, deferred: 2))
        #expect(ledger.failures.isEmpty)
    }

    @Test("si no se puede leer qué receta se eligió, falla esa grabación y las demás siguen")
    func elegidaIlegible() async throws {
        let ledger = MemoryLedger()
        let shelf = RecipeShelf(recipes: { [] }, target: { objetivo($0 ?? "defecto") })
        let runtime = RecipeRuntime(name: "falso") { _, bridge in try await transcribeYGuarda(bridge) }
        let tuberia = Pipeline(
            source: RecordingSource(
                name: "falsa", locations: [],
                chosenRecipe: { if $0.key == "a" { throw FakeError.scanBroken } else { nil } }
            ) { [recording("a"), recording("b", minute: 1)] },
            ledger: ledger.port, backend: backend { _ in Transcript(text: "hola") },
            sink: { note in URL(fileURLWithPath: "/salida/\(note.recording.key)") },
            recipe: Recipe(shelf: shelf, runtime: runtime, publishers: [:]))

        let outcome = try await tuberia.runOnce()

        #expect(outcome == PassOutcome(processed: 1, deferred: 0))
        #expect(ledger.doneKeys == ["b"])
        #expect(ledger.failures == ["a": "\(FakeError.scanBroken)"])
    }

    @Test("si las recetas no arrancan, lo que se eligió con receta falla diciéndolo y lo demás sigue sin receta")
    func elegidaSinRecetas() async throws {
        let ledger = MemoryLedger()
        let tuberia = Pipeline(
            source: RecordingSource(name: "falsa", locations: [], chosenRecipe: { $0.key == "a" ? "reparto" : nil }) {
                [recording("a"), recording("b", minute: 1)]
            },
            ledger: ledger.port, backend: backend { _ in Transcript(text: "hola") },
            sink: { note in URL(fileURLWithPath: "/salida/\(note.recording.key)") })

        let outcome = try await tuberia.runOnce()

        #expect(outcome == PassOutcome(processed: 1, deferred: 0))
        #expect(ledger.doneKeys == ["b"])
        #expect(ledger.failures == [
            "a": "la receta elegida para esta grabación no está disponible: las recetas no arrancan en este Mac",
        ])
    }

    @Test("la receta ve de donde viene la grabacion")
    func origen() async throws {
        let visto = Mutex<RecipeOrigin?>(nil)
        let origen = RecipeOrigin(kind: .folder, name: "Notas de Voz", path: "/Recordings")
        let runtime = RecipeRuntime(name: "falso") { _, bridge in
            visto.withLock { $0 = bridge.audio.origin }
            try await transcribeYGuarda(bridge)
        }

        try await Pipeline(
            source: source([recording("a")]), ledger: MemoryLedger().port,
            backend: backend { _ in Transcript(text: "hola") },
            sink: { note in URL(fileURLWithPath: "/salida/\(note.recording.key)") },
            recipe: Recipe(
                shelf: .only(objetivo("x")), runtime: runtime, publishers: [:],
                catalog: RecipeCatalog(origin: { _ in origen }))
        ).runOnce()

        #expect(visto.withLock { $0 } == origen)
    }

    @Test("la receta recibe sus parametros y la traza lleva su clave y su nombre")
    func parametrosYTraza() async throws {
        let recibidos = Mutex<String?>(nil)
        let eventos = Trace<PipelineEvent>()
        let shelf = RecipeShelf(recipes: { [] }, target: { _ in objetivo("reuniones", parametros: dataText(formRecipeValues(ajustes))) })
        let runtime = RecipeRuntime(name: "falso") { _, bridge in
            recibidos.withLock { $0 = bridge.values }
            try await transcribeYGuarda(bridge)
        }

        try await pipeline([recording("a")], shelf: shelf, runtime: runtime, eventos: eventos).runOnce()

        let traza = try #require(eventos.values.compactMap { event in
            if case .traced(_, let trace) = event { trace } else { nil }
        }.first)
        #expect(recibidos.withLock { $0 } == dataText(formRecipeValues(ajustes)))
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
            values: dataText(formRecipeValues(ajustes))))
    }

    @Test("la por defecto de codigo ejecuta su paquete instalado, sin valores si nadie los cambió")
    func deCodigoPorDefecto() throws {
        var libro = RecipeBook(migrating: ajustes, key: "F1")
        libro.makeDefault("ideas")

        let target = try estante(libro, ["ideas": instalada("ideas", "Ideas")]).target(nil)

        #expect(target == RecipeTarget(
            key: "ideas", name: "Ideas", kind: .code,
            package: RecipePackage(key: "ideas", source: "/* ideas */", fingerprint: "f-ideas")))
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
        libro.add(key: "F2", name: "Reuniones")
        let shelf = estante(libro, ["ideas": instalada("ideas", "Ideas")])

        #expect(try shelf.target("reuniones").key == "F2")
        #expect(try shelf.target("IDEAS").key == "ideas")
        #expect(try shelf.target("F1").name == "Por defecto")
        #expect(throws: RecipeLookupError.missing(kind: .recipe, query: "nada")) { try shelf.target("nada") }
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
