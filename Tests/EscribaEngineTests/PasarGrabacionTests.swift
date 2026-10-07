import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private typealias Flujo = @Sendable (RecipeBridge) async throws -> Void

private let reuniones = DefaultRecipeSettings(
    stt: "whisper", language: "es", detectSpeakers: true, speakerCount: 2, summarize: false, llm: "apple",
    prompt: nil, connectors: [])

private struct Recetario {
    let recetas: [RecipeTarget]
    let flujos: [String: Flujo]

    init(_ recetas: [(RecipeTarget, Flujo)]) {
        self.recetas = recetas.map(\.0)
        flujos = Dictionary(uniqueKeysWithValues: recetas.map { ($0.0.key, $0.1) })
    }

    var shelf: RecipeShelf {
        let recetas = recetas
        return RecipeShelf(
            recipes: { recetas.map(\.info) },
            target: { query in
                guard let query else { return recetas[0] }
                let info = try recipeLookup(query, in: recetas.map(\.info), kind: .recipe, key: \.key, name: \.name)
                return recetas.first { $0.key == info.key }!
            })
    }

    var runtime: RecipeRuntime {
        let flujos = flujos
        return RecipeRuntime(name: "falso") { package, bridge in try await flujos[package.key]!(bridge) }
    }
}

private func receta(_ key: String, _ name: String, parametros: DefaultRecipeSettings? = nil) -> RecipeTarget {
    RecipeTarget(
        key: key, name: name, kind: parametros == nil ? .code : .form,
        package: RecipePackage(key: key, source: "", fingerprint: "f-\(key)"), parameters: parametros)
}

private let transcribeYGuarda: Flujo = { escriba in
    _ = try await escriba.transcribe(RecipeTranscription())
    try await escriba.save()
}

private func pasa(_ destino: String) -> Flujo {
    { escriba in try await escriba.process(destino) }
}

private func ejecutar(
    _ recetario: Recetario, ledger: MemoryLedger = MemoryLedger(), eventos: Trace<PipelineEvent> = Trace()
) async throws -> RecipeTrace? {
    try await Pipeline(
        source: source([recording("a")]), ledger: ledger.port,
        backend: backend { _ in Transcript(text: "hola") },
        sink: { note in URL(fileURLWithPath: "/salida/\(note.recording.key)") },
        recipe: Recipe(shelf: recetario.shelf, runtime: recetario.runtime, publishers: [:]),
        onEvent: { eventos.append($0) }
    ).runOnce()
    return eventos.values.compactMap { event in
        if case .traced(_, let trace) = event { trace } else { nil }
    }.last
}

@Suite("Una receta pasa la grabacion a otra")
struct PasarGrabacionTests {
    @Test("procesar ejecuta la otra receta sobre la misma grabacion, y su guardar cuenta para las dos")
    func pasaYGuarda() async throws {
        let ledger = MemoryLedger()

        let traza = try await ejecutar(Recetario([
            (receta("reparto", "Reparto"), pasa("Reuniones")),
            (receta("F1", "Reuniones", parametros: reuniones), transcribeYGuarda),
        ]), ledger: ledger)

        #expect(ledger.doneKeys == ["a"])
        #expect(traza?.recipe == "reparto")
        #expect(traza?.steps.map(\.capability) == ["transcribir", "guardar", "receta"])
        #expect(traza?.steps.map(\.origin) == ["Reuniones", "Reuniones", nil])
        #expect(traza?.steps.map(\.title).suffix(2) == ["Reuniones › guardar", "receta · Reuniones"])
    }

    @Test("cada receta recibe sus propios parametros y ve la lista de recetas")
    func parametrosPropios() async throws {
        let vistos = Mutex<[String: DefaultRecipeSettings?]>([:])
        let listas = Mutex<[[RecipeInfo]]>([])
        let recetario = Recetario([
            (receta("reparto", "Reparto"), { @Sendable escriba in
                vistos.withLock { $0["reparto"] = escriba.parameters }
                listas.withLock { $0.append(escriba.recipes) }
                try await escriba.process("F1")
            }),
            (receta("F1", "Reuniones", parametros: reuniones), { @Sendable escriba in
                vistos.withLock { $0["F1"] = escriba.parameters }
                try await transcribeYGuarda(escriba)
            }),
        ])

        _ = try await ejecutar(recetario)

        #expect(vistos.withLock { $0["reparto"] } == .some(nil))
        #expect(vistos.withLock { $0["F1"] } == reuniones)
        #expect(listas.withLock { $0 } == [[
            RecipeInfo(key: "reparto", name: "Reparto", kind: .code),
            RecipeInfo(key: "F1", name: "Reuniones", kind: .form),
        ]])
    }

    @Test("una receta que no existe es un error que la receta puede recoger")
    func noExiste() async throws {
        let ledger = MemoryLedger()

        let traza = try await ejecutar(Recetario([
            (receta("reparto", "Reparto"), { @Sendable escriba in
                do {
                    try await escriba.process("nada")
                } catch {
                    escriba.log("sigo yo: \(error)")
                }
                try await transcribeYGuarda(escriba)
            }),
        ]), ledger: ledger)

        #expect(ledger.doneKeys == ["a"])
        #expect(traza?.steps.first?.title == "receta · nada")
        #expect(traza?.steps.first?.error == "no hay ninguna receta «nada»")
        #expect(traza?.logs == ["sigo yo: no hay ninguna receta «nada»"])
    }

    @Test("dos recetas que se llaman en circulo fallan con la cadena, y la nota queda fallida")
    func ciclo() async throws {
        let ledger = MemoryLedger()

        _ = try await ejecutar(Recetario([
            (receta("a", "Reparto"), pasa("Reuniones")),
            (receta("b", "Reuniones"), pasa("Reparto")),
        ]), ledger: ledger)

        #expect(ledger.failures["a"]?.contains("las recetas se llaman en círculo: Reparto → Reuniones → Reparto") == true)
    }

    @Test("pasar del limite de recetas encadenadas falla")
    func profundidad() async throws {
        let ledger = MemoryLedger()
        let cadena = (1...6).map { receta("r\($0)", "R\($0)") }

        _ = try await ejecutar(Recetario(cadena.enumerated().map { indice, objetivo in
            (objetivo, indice + 1 < cadena.count ? pasa(cadena[indice + 1].key) : transcribeYGuarda)
        }), ledger: ledger)

        #expect(ledger.failures["a"]?.contains("demasiadas recetas encadenadas") == true)
    }
}

@Suite("Ejecutar una receta fuera del pipeline, para reprocesar")
struct EjecutarRecetaTests {
    @Test("transcribe el audio de la biblioteca pero entrega la grabacion con su origen, y devuelve la traza")
    func audioDeLaBiblioteca() async throws {
        let oidos = Trace<String>()
        let entregadas = Trace<String>()
        let original = recording("a")
        let copia = URL(fileURLWithPath: "/biblioteca/audio/a.m4a")
        let objetivo = receta("F1", "Reuniones", parametros: reuniones)

        let (resultado, traza) = await runRecipe(
            objetivo, of: Recipe(shelf: .only(objetivo), runtime: Recetario([(objetivo, transcribeYGuarda)]).runtime, publishers: [:]),
            on: original, audio: copia,
            backend: backend { url in
                oidos.append(url.path)
                return Transcript(text: "hola")
            },
            enrich: nil, memory: nil,
            save: { note in
                entregadas.append(note.recording.url.path)
                return URL(fileURLWithPath: "/salida/a")
            })

        #expect(try resultado.get().transcript.text == "hola")
        #expect(oidos.values == ["/biblioteca/audio/a.m4a"])
        #expect(entregadas.values == [original.url.path])
        #expect(traza.recipe == "F1")
        #expect(traza.steps.map(\.capability) == ["transcribir", "guardar"])
    }

    @Test("una receta que no guarda falla con su traza")
    func sinGuardar() async {
        let objetivo = receta("x", "X")

        let (resultado, traza) = await runRecipe(
            objetivo, of: Recipe(shelf: .only(objetivo), runtime: Recetario([(objetivo, { @Sendable _ in })]).runtime, publishers: [:]),
            on: recording("a"), backend: backend { _ in Transcript(text: "hola") }, enrich: nil, memory: nil,
            save: { _ in URL(fileURLWithPath: "/salida/a") })

        #expect(throws: RecipeError.notSaved) { try resultado.get() }
        #expect(traza.error == "\(RecipeError.notSaved)")
    }
}
