import Foundation
import Testing
import EscribaCore
import EscribaEngine

@testable import EscribaOpenAI

private let servicio = OpenAIEndpoint(baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", apiKey: { "gsk-1" })

private func transcriptor(_ servidor: ServidorFalso, idioma: String? = "es", modelo: String = "whisper-large-v3-turbo")
    -> TranscriptionBackend
{
    openAITranscriber(
        name: "Groq",
        endpoint: OpenAIEndpoint(baseURL: servicio.baseURL, model: modelo, apiKey: servicio.apiKey),
        language: idioma, transport: servidor.transporte,
        readAudio: { _ in Data("AUDIO".utf8) }, boundary: { "LIMITE" })
}

private let detallada = #"""
    {"task":"transcribe","language":"spanish","duration":12.5,"text":"Hola. ¿Qué tal?",
     "segments":[{"id":0,"start":0.0,"end":4.2,"text":" Hola."},{"id":1,"start":4.2,"end":9.0,"text":"  "},
                 {"id":2,"start":9.0,"end":12.5,"text":" ¿Qué tal?"}]}
    """#

@Suite("Transcribir con una API compatible con OpenAI")
struct TranscripcionRemotaTests {
    @Test("la peticion es un multipart con el audio, el modelo, el idioma y la transcripcion por tramos")
    func peticionDetallada() {
        let peticion = transcriptionRequest(
            audio: Data("AUDIO".utf8), fileName: "Reunión.m4a", language: "es", endpoint: servicio,
            format: .detailed, boundary: "LIMITE")
        let cuerpo = texto(peticion.body)

        #expect(peticion.method == "POST")
        #expect(peticion.url == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(peticion.headers["Content-Type"] == "multipart/form-data; boundary=LIMITE")
        #expect(peticion.headers["Authorization"] == "Bearer gsk-1")
        #expect(cuerpo.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        #expect(cuerpo.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        #expect(cuerpo.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n"))
        #expect(cuerpo.contains("name=\"language\"\r\n\r\nes\r\n"))
        #expect(cuerpo.contains("name=\"file\"; filename=\"Reunión.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n"))
        #expect(cuerpo.hasSuffix("--LIMITE--\r\n"))
    }

    @Test("en formato simple no pide tramos, y sin idioma deja que el servicio lo detecte")
    func peticionSimple() {
        let cuerpo = texto(transcriptionRequest(
            audio: Data(), fileName: "nota.mp3", language: nil, endpoint: servicio, format: .plain, boundary: "L").body)

        #expect(cuerpo.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(!cuerpo.contains("timestamp_granularities"))
        #expect(!cuerpo.contains("name=\"language\""))
        #expect(cuerpo.contains("Content-Type: audio/mpeg"))
    }

    @Test("los tramos con tiempos se convierten en segmentos y los vacios se descartan")
    func tramos() throws {
        let transcripcion = try transcript(fromTranscription: Data(detallada.utf8))

        #expect(transcripcion.segments == [
            TranscriptSegment(start: 0, end: 4.2, text: "Hola."),
            TranscriptSegment(start: 9, end: 12.5, text: "¿Qué tal?"),
        ])
    }

    @Test("una respuesta solo con texto queda como un unico segmento")
    func soloTexto() throws {
        let transcripcion = try transcript(fromTranscription: Data(#"{"text":" Hola, ¿qué tal? "}"#.utf8))

        #expect(transcripcion.segments == [TranscriptSegment(start: 0, end: 0, text: "Hola, ¿qué tal?")])
        #expect(try transcript(fromTranscription: Data(#"{"text":"  "}"#.utf8)).segments.isEmpty)
        #expect(throws: RemoteAPIError.self) { try transcript(fromTranscription: Data("<html>".utf8)) }
    }

    @Test("transcribe leyendo el fichero y llamando a /audio/transcriptions")
    func transcribe() async throws {
        let servidor = ServidorFalso(json: detallada)

        let transcripcion = try await transcriptor(servidor).transcribe(URL(fileURLWithPath: "/notas/Reunión.m4a"))

        #expect(transcripcion.text == "Hola.\n¿Qué tal?")
        #expect(servidor.peticiones.count == 1)
        #expect(texto(servidor.peticiones[0].body).contains("filename=\"Reunión.m4a\""))
    }

    @Test("si el modelo no da tramos con tiempos, repite una vez en formato simple")
    func sinTramos() async throws {
        let servidor = ServidorFalso([
            respuesta(400, errorDeAPI("response_format 'verbose_json' is not compatible with model 'gpt-4o-transcribe'")),
            respuesta(200, #"{"text":"Hola."}"#),
        ])

        let transcripcion = try await transcriptor(servidor, modelo: "gpt-4o-transcribe").transcribe(URL(fileURLWithPath: "/n.m4a"))

        #expect(transcripcion.text == "Hola.")
        #expect(servidor.peticiones.count == 2)
        #expect(texto(servidor.peticiones[1].body).contains("name=\"response_format\"\r\n\r\njson\r\n"))
    }

    @Test("sin red, con la clave mal o con el servicio caido, la nota espera al siguiente ciclo en vez de fallar")
    func esperar() async {
        for caso in [Result<RemoteResponse, FalloDeRed>.failure(FalloDeRed()), respuesta(401, errorDeAPI("bad key")), respuesta(503, "")] {
            do {
                _ = try await transcriptor(ServidorFalso([caso])).transcribe(URL(fileURLWithPath: "/n.m4a"))
                Issue.record("tenia que fallar")
            } catch {
                #expect(error.isBackendUnavailable, "\(error)")
            }
        }
    }

    @Test("un audio demasiado grande o que el servicio rechaza marca solo esa nota como fallida")
    func fallaLaNota() async {
        for caso in [respuesta(413, ""), respuesta(400, errorDeAPI("Invalid file format."))] {
            do {
                _ = try await transcriptor(ServidorFalso([caso])).transcribe(URL(fileURLWithPath: "/n.m4a"))
                Issue.record("tenia que fallar")
            } catch {
                #expect(!error.isBackendUnavailable, "\(error)")
            }
        }
    }

    @Test("sin modelo o con una URL mala, la comprobacion previa lo dice sin llamar a nadie")
    func comprobacionPrevia() {
        let servidor = ServidorFalso(json: "{}")

        #expect(throws: TranscriptionError.self) { try transcriptor(servidor, modelo: "").preflight() }
        #expect(throws: Never.self) { try transcriptor(servidor).preflight() }
        #expect(servidor.peticiones.isEmpty)
    }

    @Test("el audio de prueba es un WAV de silencio valido")
    func audioDePrueba() {
        let wav = silentWAV(seconds: 1, sampleRate: 16_000)

        #expect(wav.count == 44 + 32_000)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav.dropFirst(8).prefix(4), as: UTF8.self) == "WAVE")
        #expect(wav.dropFirst(44).allSatisfy { $0 == 0 })
    }
}
