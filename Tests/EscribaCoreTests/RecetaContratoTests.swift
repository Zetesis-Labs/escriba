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

private func opciones(_ json: String) throws -> RecipeTranscription {
    try JSONDecoder().decode(RecipeTranscription.self, from: Data(json.utf8))
}

private let resolutores = [
    RecipeResolver(key: "whisper", name: "Whisper en este Mac", isLocal: true),
    RecipeResolver(key: "A1", name: "OpenAI", isLocal: false),
    RecipeResolver(key: "B2", name: "Groq", isLocal: false),
    RecipeResolver(key: "C3", name: "groq", isLocal: false),
]

@Suite("Lo que una receta elige")
struct RecetaEleccionTests {
    @Test("un STT, un LLM o un conector se piden por su clave o por su nombre, sin distinguir mayusculas")
    func busqueda() throws {
        #expect(try recipeLookup("whisper", in: resolutores, kind: .stt, key: \.key, name: \.name).key == "whisper")
        #expect(try recipeLookup("openai", in: resolutores, kind: .stt, key: \.key, name: \.name).key == "A1")
        #expect(try recipeLookup("B2", in: resolutores, kind: .stt, key: \.key, name: \.name).name == "Groq")
    }

    @Test("lo que no existe falla diciendo que, y un nombre repetido pide la clave")
    func busquedaFallida() {
        #expect(throws: RecipeLookupError.missing(kind: .stt, query: "Deepgram")) {
            try recipeLookup("Deepgram", in: resolutores, kind: .stt, key: \.key, name: \.name)
        }
        #expect(throws: RecipeLookupError.ambiguous(kind: .stt, query: "GROQ")) {
            try recipeLookup("GROQ", in: resolutores, kind: .stt, key: \.key, name: \.name)
        }
        #expect("\(RecipeLookupError.missing(kind: .connector, query: "x"))" == "no hay ningún conector «x»")
        #expect("\(RecipeLookupError.ambiguous(kind: .llm, query: "x"))" == "el nombre «x» lo llevan varios: usa su clave")
    }

    @Test("sin opciones se transcribe con lo de la carpeta")
    func sinOpciones() throws {
        let carpeta = TranscriptionOptions(language: "es", diarize: true, speakerCount: 3)

        #expect(try opciones("{}").isDefault)
        #expect(try opciones("{}").options(over: carpeta) == carpeta)
    }

    @Test("el idioma tiene tres estados: el de la carpeta, automatico con null o uno concreto")
    func idioma() throws {
        let carpeta = TranscriptionOptions(language: "es")

        #expect(try opciones("{}").options(over: carpeta).language == "es")
        #expect(try opciones(#"{"idioma": null}"#).options(over: carpeta).language == nil)
        #expect(try opciones(#"{"idioma": "en"}"#).options(over: carpeta).language == "en")
        #expect(try !opciones(#"{"idioma": null}"#).isDefault)
    }

    @Test("los hablantes se detectan o no, y se puede fijar cuantos")
    func hablantes() throws {
        let carpeta = TranscriptionOptions(language: "es", diarize: true, speakerCount: 3)

        #expect(try opciones(#"{"hablantes": {"detectar": false}}"#).options(over: carpeta)
            == TranscriptionOptions(language: "es"))
        #expect(try opciones(#"{"hablantes": {"detectar": true, "cuantos": 2}}"#).options(over: carpeta)
            == TranscriptionOptions(language: "es", diarize: true, speakerCount: 2))
        #expect(try opciones(#"{"hablantes": {"detectar": true}}"#).options(over: TranscriptionOptions())
            == TranscriptionOptions(diarize: true))
    }

    @Test("el STT elegido viaja en las opciones")
    func sttElegido() throws {
        #expect(try opciones(#"{"stt": "groq"}"#).stt == "groq")
        #expect(try !opciones(#"{"stt": "groq"}"#).isDefault)
    }

    @Test("un STT remoto no detecta hablantes: pedirlo es un error, no texto sin hablantes")
    func remotoSinHablantes() {
        #expect(transcriptionProblem(isLocal: false, options: TranscriptionOptions(diarize: true)) != nil)
        #expect(transcriptionProblem(isLocal: false, options: TranscriptionOptions(language: "es")) == nil)
        #expect(transcriptionProblem(isLocal: true, options: TranscriptionOptions(diarize: true)) == nil)
    }

    @Test("resumir sin opciones usa lo de la carpeta; con LLM o prompt, lo pedido")
    func resumen() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RecipeSummaryRequest.self, from: Data("{}".utf8)).isDefault)
        let pedido = try decoder.decode(RecipeSummaryRequest.self, from: Data(#"{"llm": "apple", "prompt": "breve"}"#.utf8))
        #expect(pedido == RecipeSummaryRequest(llm: "apple", prompt: "breve"))
        #expect(!pedido.isDefault)
    }

    @Test("los resolutores llegan con su configuracion, sin claves de API")
    func resolutorConfigurado() throws {
        let remoto = try objeto(try recipeJSON(RecipeResolver(
            key: "A1", name: "Groq", isLocal: false,
            model: "llama-3.3-70b", baseURL: "https://api.groq.com/openai/v1")))
        let local = try objeto(try recipeJSON(resolutores[0]))

        #expect(Set(remoto.keys) == ["clave", "nombre", "local", "modelo", "url"])
        #expect(remoto["modelo"] as? String == "llama-3.3-70b")
        #expect(remoto["url"] as? String == "https://api.groq.com/openai/v1")
        #expect(local["local"] as? Bool == true)
        #expect(local["modelo"] is NSNull)
        #expect(local["url"] is NSNull)
    }

    @Test("los conectores llegan con si estan activos y su destino, sin su token")
    func conectorConfigurado() throws {
        let notion = try objeto(try recipeJSON(RecipeConnector(
            key: "K", name: "Notion trabajo", kind: "notion", isActive: true,
            notionBase: RecipeConnector.NotionBase(id: "db1", name: "Voice Inbox"))))
        let okf = try objeto(try recipeJSON(RecipeConnector(
            key: "O", name: "Ideas", kind: "okf", isActive: false, folder: "/Users/r/ideas")))
        let base = try #require(notion["base"] as? [String: Any])

        #expect(Set(notion.keys) == ["clave", "nombre", "tipo", "activo", "base", "carpeta"])
        #expect(notion["activo"] as? Bool == true)
        #expect(base["id"] as? String == "db1")
        #expect(base["nombre"] as? String == "Voice Inbox")
        #expect(notion["carpeta"] is NSNull)
        #expect(okf["activo"] as? Bool == false)
        #expect(okf["base"] is NSNull)
        #expect(okf["carpeta"] as? String == "/Users/r/ideas")
    }
}
