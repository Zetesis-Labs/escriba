import Foundation
import Testing

@testable import EscribaCore

private func objeto(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Suite("Contrato de una receta: lo que ve JavaScript")
struct RecetaContratoTests {
    @Test("el audio de una grabacion lleva su clave, su nombre y su fecha en ISO")
    func audio() throws {
        let recording = Recording(
            url: URL(fileURLWithPath: "/bandeja/Grabación 2026-10-07 16.14.20.m4a"),
            startedAt: Date(timeIntervalSince1970: 0),
            key: "Escriba/Grabación 2026-10-07 16.14.20")

        let audio = try objeto(try recipeJSON(recipeAudio(recording)))

        #expect(audio["clave"] as? String == "Escriba/Grabación 2026-10-07 16.14.20")
        #expect(audio["nombre"] as? String == "Grabación 2026-10-07 16.14.20")
        #expect(audio["fecha"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test("la nota llega con texto, hablantes, segmentos con palabras y resumen, con los nombres del contrato")
    func nota() throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                start: 0, end: 1.5, speaker: "Ana", text: "Hola, que tal.",
                words: [TranscriptWord(start: 0, end: 0.4, text: "Hola,")]),
        ])
        let note = RecipeNote(
            key: "a", version: 3, transcript: transcript,
            digest: Digest(title: "Saludo", summary: "Ana saluda.", tags: ["x"]))

        let json = try objeto(try recipeJSON(note))
        let segmento = try #require((json["segmentos"] as? [[String: Any]])?.first)
        let palabra = try #require((segmento["palabras"] as? [[String: Any]])?.first)
        let resumen = try #require(json["resumen"] as? [String: Any])

        #expect(json["clave"] as? String == "a")
        #expect(json["version"] as? Int == 3)
        #expect(json["texto"] as? String == transcript.text)
        #expect(json["hablantes"] as? [String] == ["Ana"])
        #expect(segmento["inicio"] as? Double == 0)
        #expect(segmento["fin"] as? Double == 1.5)
        #expect(segmento["hablante"] as? String == "Ana")
        #expect(segmento["texto"] as? String == "Hola, que tal.")
        #expect(palabra["texto"] as? String == "Hola,")
        #expect(resumen["titulo"] as? String == "Saludo")
        #expect(resumen["texto"] as? String == "Ana saluda.")
        #expect(resumen["etiquetas"] as? [String] == ["x"])
    }

    @Test("cada paso de la traza se lee como su capacidad y, si lo hay, su detalle")
    func pasoDeLaTraza() {
        #expect(RecipeStep(capability: "publicar", detail: "notion", seconds: 0, error: nil).title == "publicar · notion")
        #expect(RecipeStep(capability: "transcribir", detail: nil, seconds: 0, error: nil).title == "transcribir")
    }

    @Test("la cabecera de la traza dice la receta y su huella corta")
    func cabeceraDeLaTraza() {
        let trace = RecipeTrace(recipe: "por-defecto", fingerprint: "b8d6dc28e0cac9eb", steps: [], logs: [], error: nil)

        #expect(trace.headline == "Receta «por-defecto» · b8d6dc2")
    }

    @Test("lo que falta llega como null, no se omite, para que JavaScript no vea undefined")
    func nulos() throws {
        let note = RecipeNote(
            key: "a", version: nil,
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "sin hablante")]),
            digest: nil)

        let json = try objeto(try recipeJSON(note))
        let segmento = try #require((json["segmentos"] as? [[String: Any]])?.first)

        #expect(json["version"] is NSNull)
        #expect(json["resumen"] is NSNull)
        #expect(segmento["hablante"] is NSNull)
    }
}
