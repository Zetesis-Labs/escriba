import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let objetivo = RecipeTarget(
    key: "x", name: "X", kind: .code, package: RecipePackage(key: "x", source: "", fingerprint: "f"))

private let completa: @Sendable (RecipeBridge) async throws -> Void = { escriba in
    _ = try await escriba.transcribe(RecipeTranscription())
    _ = try await escriba.summarize(RecipeSummaryRequest())
    try await escriba.save()
    try await escriba.publish("Notion")
}

private func probar(
    memoria: MemoryNotes, pasos: Trace<String>, transcribe: TranscriptionBackend? = nil
) async -> (Result<(transcript: Transcript, output: URL), any Error>, RecipeTrace) {
    let recipe = Recipe(
        shelf: .only(objetivo), runtime: RecipeRuntime(name: "falso") { _, bridge in try await completa(bridge) },
        publishers: ["K1": { _ in
            pasos.append("publica")
            return URL(fileURLWithPath: "/notion")
        }],
        catalog: RecipeCatalog(connectors: [RecipeConnector(key: "K1", name: "Notion", kind: "notion")]))
    return await runRecipe(
        objetivo, of: recipe, on: recording("a"),
        backend: transcribe ?? backend { _ in
            pasos.append("transcribe")
            return Transcript(text: "hola")
        },
        enrich: { _, _ in
            pasos.append("resume")
            return Digest(title: "Hola", summary: "Adiós", tags: [])
        },
        memory: memoria.port,
        save: { _ in
            pasos.append("guarda")
            return URL(fileURLWithPath: "/salida/a")
        },
        dryRun: true)
}

@Suite("Probar una receta sin tocar nada")
struct ProbarRecetaTests {
    @Test("probar ejecuta todo menos guardar y publicar, y la traza dice que no publico")
    func sinEfectos() async throws {
        let memoria = MemoryNotes()
        let pasos = Trace<String>()

        let (resultado, traza) = await probar(memoria: memoria, pasos: pasos)

        #expect(try resultado.get().transcript.text == "hola")
        #expect(pasos.values == ["transcribe", "resume"])
        #expect(memoria.count == 0)
        #expect(traza.steps.map(\.title) == [
            "transcribir · falso · \(TranscriptionOptions.automatic.label)", "resumir", "guardar · sin guardar (prueba)",
            "publicar · Notion · sin publicar (prueba)",
        ])
    }

    @Test("probar aprovecha lo que ya esta transcrito y resumido en la biblioteca")
    func aprovecha() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "guardada"), digest: Digest(title: "T", summary: "S", tags: []))
        let pasos = Trace<String>()

        let (resultado, _) = await probar(memoria: memoria, pasos: pasos)

        #expect(try resultado.get().transcript.text == "guardada")
        #expect(pasos.values.isEmpty)
    }
}
