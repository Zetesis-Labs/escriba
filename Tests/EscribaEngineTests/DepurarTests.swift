import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private func objetivo(_ key: String, _ name: String) -> RecipeTarget {
    RecipeTarget(
        key: key, name: name, kind: .code, package: RecipePackage(key: key, source: "", fingerprint: "f-\(key)"))
}

private func ejecutar(
    _ flujos: [(RecipeTarget, @Sendable (RecipeBridge) async throws -> Void)],
    backend transcribe: TranscriptionBackend = backend { _ in Transcript(text: "hola") }
) async -> RecipeTrace {
    let targets = flujos.map(\.0)
    let porClave = Dictionary(uniqueKeysWithValues: flujos.map { ($0.0.key, $0.1) })
    let recipe = Recipe(
        shelf: RecipeShelf(
            recipes: { targets.map(\.info) },
            target: { query in targets.first { $0.key == query || $0.name == query } ?? targets[0] }),
        runtime: RecipeRuntime(name: "falso") { package, bridge in try await porClave[package.key]!(bridge) },
        publishers: [:])
    return await runRecipe(
        targets[0], of: recipe, on: recording("a"), backend: transcribe, enrich: nil, memory: nil,
        save: { _ in URL(fileURLWithPath: "/salida/a") }
    ).trace
}

@Suite("Depurar una receta: log con niveles, resultado y recorrido")
struct DepurarTests {
    @Test("cada linea de log lleva su nivel, la receta que la escribio y cuando")
    func lineas() async {
        let traza = await ejecutar([
            (objetivo("reparto", "Reparto"), { @Sendable escriba in
                escriba.log(.info, "empiezo")
                try await escriba.process("Reuniones")
                escriba.log(.warn, "vuelvo")
            }),
            (objetivo("F1", "Reuniones"), { @Sendable escriba in
                escriba.log(.error, "dentro")
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.save()
            }),
        ])

        #expect(traza.logs.map(\.level) == [.info, .error, .warn])
        #expect(traza.logs.map(\.text) == ["empiezo", "dentro", "vuelvo"])
        #expect(traza.logs.map(\.origin) == [nil, "Reuniones", nil])
        #expect(traza.logs.allSatisfy { $0.seconds >= 0 })
        #expect(traza.logs.map(\.seconds) == traza.logs.map(\.seconds).sorted())
    }

    @Test("la traza lleva las recetas por las que paso, por clave, y cuando empezo y cuanto tardo")
    func recorrido() async {
        let antes = Date()

        let traza = await ejecutar([
            (objetivo("reparto", "Reparto"), { @Sendable escriba in try await escriba.process("Reuniones") }),
            (objetivo("F1", "Reuniones"), { @Sendable escriba in
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.save()
            }),
        ])

        #expect(traza.recipes == ["reparto", "F1"])
        #expect(traza.startedAt.map { $0 >= antes } == true)
        #expect(traza.seconds.map { $0 >= 0 } == true)
    }

    @Test("el resultado de una ejecucion: bien, fallo, o esperando si el motor no responde")
    func resultado() async {
        let guarda: @Sendable (RecipeBridge) async throws -> Void = { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            try await escriba.save()
        }

        let bien = await ejecutar([(objetivo("x", "X"), guarda)])
        let fallo = await ejecutar([(objetivo("x", "X"), { @Sendable _ in throw RecipeError.failed("mal") })])
        let esperando = await ejecutar(
            [(objetivo("x", "X"), guarda)],
            backend: backend { _ throws(TranscriptionError) in throw .backendUnavailable("sin red") })

        #expect(bien.outcome == .ok)
        #expect(fallo.outcome == .failed)
        #expect(esperando.outcome == .waiting)
    }
}
