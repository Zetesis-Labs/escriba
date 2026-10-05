import Foundation
import Synchronization
import Testing
import EscribaCore
import EscribaEngine

@testable import EscribaOpenAI

private func resumidor(_ servidor: ServidorFalso, modelo: String = "gpt-x", url: String = "https://api.openai.com/v1")
    -> Summarizer
{
    openAISummarizer(
        name: "OpenAI", endpoint: OpenAIEndpoint(baseURL: url, model: modelo, apiKey: { "sk-1" }),
        transport: servidor.transporte)
}

@Suite("Resumir con una API compatible con OpenAI")
struct ResumenRemotoTests {
    @Test("resume de una vez, con el prompt del resumidor, y sale normalizado")
    func resume() async throws {
        let servidor = ServidorFalso(json: chat(##"{"title":"\"Backups.\"","summary":" Se habló de MinIO. ","tags":["#Backups"]}"##))

        let digest = try await resumidor(servidor).prompted("Resume como un acta.")
            .digest(of: "Hablamos de backups.", language: "es")

        #expect(digest == Digest(title: "Backups", summary: "Se habló de MinIO.", tags: ["backups"]))
        #expect(servidor.peticiones.count == 1)
        #expect(servidor.peticiones[0].url == "https://api.openai.com/v1/chat/completions")
        let sistema = (json(servidor.peticiones[0].body)["messages"] as? [[String: String]])?.first?["content"]
        #expect(sistema?.hasPrefix("Resume como un acta.") == true)
        #expect(sistema?.contains("español") == true)
    }

    @Test("si el servicio no admite esquemas, repite una vez pidiendo un objeto JSON")
    func sinEsquemas() async throws {
        let servidor = ServidorFalso([
            respuesta(400, errorDeAPI("Invalid parameter: 'response_format' of type 'json_schema' is not supported with this model.")),
            respuesta(200, chat(#"{"title":"T","summary":"R","tags":[]}"#)),
        ])

        let digest = try await resumidor(servidor).digest(of: "Hola.", language: nil)

        #expect(digest.title == "T")
        #expect(servidor.peticiones.count == 2)
        #expect((json(servidor.peticiones[1].body)["response_format"] as? [String: String]) == ["type": "json_object"])
    }

    @Test("un rechazo que no va del formato no se repite")
    func sinRepetir() async {
        let servidor = ServidorFalso([respuesta(400, errorDeAPI("context_length_exceeded"))])

        await #expect(throws: SummaryError.failed(RemoteAPIError.rejected(status: 400, message: "context_length_exceeded").message)) {
            try await resumidor(servidor).digest(of: "Hola.", language: nil)
        }
        #expect(servidor.peticiones.count == 1)
    }

    @Test("una clave rechazada deja el resumidor no disponible con el motivo")
    func claveRechazada() async {
        let servidor = ServidorFalso([respuesta(401, errorDeAPI("Incorrect API key provided"))])

        await #expect(throws: SummaryError.unavailable(RemoteAPIError.unauthorized("Incorrect API key provided").message)) {
            try await resumidor(servidor).digest(of: "Hola.", language: nil)
        }
    }

    @Test("sin modelo o con una URL mala no esta disponible y no llama a nadie")
    func disponibilidad() async {
        let servidor = ServidorFalso(json: chat("{}"))

        #expect(resumidor(servidor, modelo: " ").availability() == .unavailable("Elige el modelo."))
        #expect(resumidor(servidor, url: "http://api.example.com/v1").availability()
            == .unavailable("Usa https:// para un servicio fuera de tu red."))
        #expect(resumidor(servidor).availability() == .ready)
        await #expect(throws: SummaryError.self) { try await resumidor(servidor, modelo: "").digest(of: "Hola.", language: nil) }
        #expect(servidor.peticiones.isEmpty)
    }

    @Test("la clave se lee en cada llamada, asi cambiarla no obliga a reconstruir nada")
    func claveViva() async throws {
        let clave = Mutex("sk-vieja")
        let servidor = ServidorFalso(json: chat(#"{"title":"T","summary":"R","tags":[]}"#), chat(#"{"title":"T","summary":"R","tags":[]}"#))
        let resumidor = openAISummarizer(
            name: "OpenAI",
            endpoint: OpenAIEndpoint(baseURL: "https://api.openai.com/v1", model: "gpt-x", apiKey: { clave.withLock { $0 } }),
            transport: servidor.transporte)

        _ = try await resumidor.digest(of: "Hola.", language: nil)
        clave.withLock { $0 = "sk-nueva" }
        _ = try await resumidor.digest(of: "Hola.", language: nil)

        #expect(servidor.peticiones.map { $0.headers["Authorization"] } == ["Bearer sk-vieja", "Bearer sk-nueva"])
    }

    @Test("los modelos del servicio se listan con la misma clave")
    func modelos() async throws {
        let servidor = ServidorFalso(json: #"{"data":[{"id":"b"},{"id":"a"}]}"#)

        let modelos = try await remoteModels(
            endpoint: OpenAIEndpoint(baseURL: "https://api.openai.com/v1", model: "", apiKey: { "sk-1" }),
            transport: servidor.transporte)

        #expect(modelos == ["a", "b"])
        #expect(servidor.peticiones.first?.headers["Authorization"] == "Bearer sk-1")
    }

    @Test("si no se llega al servicio, el fallo dice a que sitio se intentaba llegar")
    func sinRed() async {
        let servidor = ServidorFalso([.failure(FalloDeRed())])

        do {
            _ = try await remoteModels(
                endpoint: OpenAIEndpoint(baseURL: "https://api.openai.com/v1", model: ""), transport: servidor.transporte)
            Issue.record("tenia que fallar")
        } catch {
            #expect(error.message.contains("api.openai.com"))
            #expect(error.blocksEveryRecording)
        }
    }
}
