import Foundation
import Testing

@testable import EscribaCore

@Suite("La receta por defecto se configura por formulario")
struct RecetaPorDefectoTests {
    @Test("los parametros llegan a JavaScript con los nombres del contrato")
    func parametros() throws {
        let ajustes = DefaultRecipeSettings(
            stt: "whisper", language: "es", detectSpeakers: true, speakerCount: 2, summarize: true, llm: "apple",
            prompt: "Tres viñetas", connectors: ["K1"])

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try recipeJSON(ajustes).utf8)) as? [String: Any])
        let hablantes = try #require(json["hablantes"] as? [String: Any])

        #expect(json["stt"] as? String == "whisper")
        #expect(json["idioma"] as? String == "es")
        #expect(hablantes["detectar"] as? Bool == true)
        #expect(hablantes["cuantos"] as? Int == 2)
        #expect(json["resumir"] as? Bool == true)
        #expect(json["llm"] as? String == "apple")
        #expect(json["prompt"] as? String == "Tres viñetas")
        #expect(json["conectores"] as? [String] == ["K1"])
    }

    @Test("lo que no se fija llega como null: idioma automatico, hablantes sin numero, prompt de serie")
    func nulos() throws {
        let ajustes = DefaultRecipeSettings(
            stt: "whisper", language: nil, detectSpeakers: false, speakerCount: nil, summarize: false, llm: "apple",
            prompt: nil, connectors: [])

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try recipeJSON(ajustes).utf8)) as? [String: Any])

        #expect(json["idioma"] is NSNull)
        #expect(json["prompt"] is NSNull)
        #expect((json["hablantes"] as? [String: Any])?["cuantos"] is NSNull)
    }

    @Test("se guarda y se vuelve a leer igual")
    func idaYVuelta() throws {
        let ajustes = DefaultRecipeSettings(
            stt: "U1", language: nil, detectSpeakers: true, speakerCount: nil, summarize: true, llm: "U2",
            prompt: nil, connectors: ["K1", "K2"])

        let leido = try JSONDecoder().decode(DefaultRecipeSettings.self, from: Data(try recipeJSON(ajustes).utf8))

        #expect(leido == ajustes)
    }

    @Test("la primera vez nace de los ajustes de hoy, para que nada cambie sin tocarlo")
    func migracion() {
        let migrada = migratedDefaultRecipe(
            stt: "whisper", llm: "apple", llmPrompt: "Breve", language: "es", diarization: 2, summarize: true,
            connectors: ["K1"])

        #expect(migrada == DefaultRecipeSettings(
            stt: "whisper", language: "es", detectSpeakers: true, speakerCount: 2, summarize: true, llm: "apple",
            prompt: "Breve", connectors: ["K1"]))
    }

    @Test("la migracion entiende idioma automatico y la deteccion de hablantes apagada o automatica")
    func migracionDeCasos() {
        let automatico = migratedDefaultRecipe(
            stt: "whisper", llm: "apple", llmPrompt: nil, language: "auto", diarization: -1, summarize: false,
            connectors: [])
        let sinNumero = migratedDefaultRecipe(
            stt: "whisper", llm: "apple", llmPrompt: "", language: "en", diarization: 0, summarize: false,
            connectors: [])

        #expect(automatico.language == nil)
        #expect(!automatico.detectSpeakers)
        #expect(automatico.speakerCount == nil)
        #expect(sinNumero.detectSpeakers)
        #expect(sinNumero.speakerCount == nil)
        #expect(sinNumero.prompt == nil)
    }
}
