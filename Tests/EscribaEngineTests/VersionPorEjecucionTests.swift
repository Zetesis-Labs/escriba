import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let objetivo = RecipeTarget(
    key: "analisis", name: "Análisis", kind: .code, package: RecipePackage(key: "analisis", source: "", fingerprint: "f"),
    parameters: nil)

private let conHablantes = TranscriptionInputs(
    backend: "falso", options: TranscriptionOptions(language: nil, diarize: true, speakerCount: nil))

private func ejecutar(
    memoria: MemoryNotes, nueva: Bool, transcribe: Trace<String> = Trace(), resume: Trace<String> = Trace(),
    _ flujo: @escaping @Sendable (RecipeBridge) async throws -> Void
) async -> (Result<(transcript: Transcript, output: URL), any Error>, RecipeTrace) {
    let recipe = Recipe(
        shelf: .only(objetivo), runtime: RecipeRuntime(name: "falso") { _, bridge in try await flujo(bridge) },
        publishers: [:],
        catalog: RecipeCatalog(transcriber: { _, _ in
            TranscriptionBackend(
                name: "falso", transcribe: { _ in
                    transcribe.append("con hablantes")
                    return Transcript(text: "con hablantes")
                }, inputs: { _ in conHablantes })
        }))
    return await runRecipe(
        objetivo, of: recipe, on: recording("a"),
        backend: backend { _ in
            transcribe.append("sin hablantes")
            return Transcript(text: "sin hablantes")
        },
        enrich: { _, _ in
            resume.append("resume")
            return Digest(title: "T", summary: "S", tags: [])
        },
        memory: memoria.port, save: { _ in URL(fileURLWithPath: "/salida/a") }, fresh: nueva)
}

@Suite("Cada reprocesado es una versión nueva de la nota")
struct VersionPorEjecucionTests {
    @Test("reprocesar crea una versión nueva copiando la transcripción que ya había y rehace el resumen")
    func nueva() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "guardada"), digest: Digest(title: "Viejo", summary: "v", tags: []))
        let transcribe = Trace<String>()
        let resume = Trace<String>()

        let (resultado, _) = await ejecutar(memoria: memoria, nueva: true, transcribe: transcribe, resume: resume) {
            escriba in
            let nota = try await escriba.transcribe(RecipeTranscription())
            #expect(nota.version == 2)
            #expect(nota.digest == nil)
            _ = try await escriba.summarize(RecipeSummaryRequest())
            try await escriba.save()
        }

        #expect(try resultado.get().transcript.text == "guardada")
        #expect(transcribe.values.isEmpty)
        #expect(resume.values == ["resume"])
        #expect(memoria.steps.values == [
            "guarda transcripcion", "guarda resumen v2", "v2 queda como la nota, de Análisis",
        ])
    }

    @Test("dentro de una misma ejecución, volver a pedir la misma transcripción no crea otra versión")
    func unaPorEjecucion() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "guardada"))

        _ = await ejecutar(memoria: memoria, nueva: true) { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            let otra = try await escriba.transcribe(RecipeTranscription())
            #expect(otra.version == 2)
            try await escriba.save()
        }

        #expect(memoria.steps.values.filter { $0 == "guarda transcripcion" }.count == 1)
    }

    @Test("lo automático reutiliza la versión que ya hay y la deja como la de la nota")
    func automatico() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "guardada"))

        _ = await ejecutar(memoria: memoria, nueva: false) { escriba in
            let nota = try await escriba.transcribe(RecipeTranscription())
            #expect(nota.version == 1)
            try await escriba.save()
        }

        #expect(memoria.steps.values == ["v1 queda como la nota, de Análisis"])
    }

    @Test("los datos guardados en una ejecución siguen a la nota a la versión que acaba guardando")
    func datosSiguen() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "sin hablantes"))
        memoria.remember("a", Transcript(text: "con hablantes"), inputs: conHablantes)
        let esquema = #"{"type":"object","properties":{"tipo":{"type":"string","title":"Tipo"}}}"#
        let esquemas = Trace<String>()
        var puerto = memoria.port
        let guardar = puerto.keepData
        puerto.keepData = { grabacion, version, datos, esquema in
            esquemas.append("v\(version) \(esquema.map { dataText($0) } ?? "sin esquema")")
            try await guardar(grabacion, version, datos, esquema)
        }
        let recipe = Recipe(
            shelf: .only(objetivo),
            runtime: RecipeRuntime(name: "falso") { _, escriba in
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.saveData(#"{"tipo":"otro"}"#, esquema)
                let delegada = try await escriba.transcribe(RecipeTranscription(speakers: .init(detect: true)))
                #expect(delegada.version == 2)
                #expect(delegada.data == (try parseData(#"{"tipo":"otro"}"#)))
                try await escriba.save()
            },
            publishers: [:],
            catalog: RecipeCatalog(transcriber: { _, _ in
                TranscriptionBackend(name: "falso", transcribe: { _ in Transcript(text: "x") }, inputs: { _ in conHablantes })
            }))

        _ = await runRecipe(
            objetivo, of: recipe, on: recording("a"), backend: backend { _ in Transcript(text: "x") }, enrich: nil,
            memory: puerto, save: { _ in URL(fileURLWithPath: "/salida/a") })

        #expect(esquemas.values == ["v1 \(esquema)", "v2 \(esquema)"])
        #expect(memoria.kept("a", inputs: conHablantes)?.data == (try parseData(#"{"tipo":"otro"}"#)))
        #expect(memoria.steps.values.last == "v2 queda como la nota, de Análisis")
    }

    @Test("probar no crea versiones aunque se pida una nueva")
    func probar() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "guardada"))
        let recipe = Recipe(
            shelf: .only(objetivo),
            runtime: RecipeRuntime(name: "falso") { _, escriba in
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.save()
            },
            publishers: [:])

        _ = await runRecipe(
            objetivo, of: recipe, on: recording("a"), backend: backend { _ in Transcript(text: "x") }, enrich: nil,
            memory: memoria.port, save: { _ in URL(fileURLWithPath: "/salida/a") }, dryRun: true, fresh: true)

        #expect(memoria.steps.values.isEmpty)
    }
}
