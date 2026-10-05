import Foundation
import Testing
import EscribaCore

@testable import EscribaOpenAI

private let servicio = OpenAIEndpoint(baseURL: "https://api.openai.com/v1/", model: "gpt-x", apiKey: { "sk-1" })

@Suite("API compatible con OpenAI: peticiones y respuestas")
struct PeticionesTests {
    @Test("la URL de cada llamada sale de la base, con o sin barra final")
    func urls() {
        #expect(endpointURL("https://api.openai.com/v1/", "chat/completions") == "https://api.openai.com/v1/chat/completions")
        #expect(endpointURL("http://localhost:1234/v1", "/models") == "http://localhost:1234/v1/models")
        #expect(endpointURL("  https://api.groq.com/openai/v1  ", "audio/transcriptions")
            == "https://api.groq.com/openai/v1/audio/transcriptions")
    }

    @Test("el resumen manda las instrucciones como sistema, el texto como usuario y pide un JSON con esquema")
    func peticionDeResumen() {
        let peticion = chatRequest(
            DigestRequest(instructions: "Resume como un acta.", prompt: "Transcripción:\nHola"),
            endpoint: servicio, format: .schema)
        let cuerpo = json(peticion.body)
        let mensajes = cuerpo["messages"] as? [[String: String]] ?? []
        let formato = cuerpo["response_format"] as? [String: Any] ?? [:]
        let esquema = (formato["json_schema"] as? [String: Any]) ?? [:]

        #expect(peticion.method == "POST")
        #expect(peticion.url == "https://api.openai.com/v1/chat/completions")
        #expect(cuerpo["model"] as? String == "gpt-x")
        #expect(mensajes.map { $0["role"] } == ["system", "user"])
        #expect(mensajes.first?["content"]?.hasPrefix("Resume como un acta.") == true)
        #expect(mensajes.first?["content"]?.contains("JSON") == true)
        #expect(mensajes.last?["content"] == "Transcripción:\nHola")
        #expect(formato["type"] as? String == "json_schema")
        #expect(esquema["strict"] as? Bool == true)
        #expect(((esquema["schema"] as? [String: Any])?["required"] as? [String]) == ["title", "summary", "tags"])
        #expect(cuerpo["temperature"] == nil)
    }

    @Test("en formato objeto pide json_object, para servicios sin esquemas")
    func formatoObjeto() {
        let peticion = chatRequest(DigestRequest(instructions: "i", prompt: "p"), endpoint: servicio, format: .object)

        #expect((json(peticion.body)["response_format"] as? [String: String]) == ["type": "json_object"])
    }

    @Test("la clave va como Bearer; sin clave no hay cabecera de autorizacion")
    func clave() {
        let conClave = modelsRequest(endpoint: servicio)
        let sinClave = modelsRequest(endpoint: OpenAIEndpoint(baseURL: "http://localhost:1234/v1", model: ""))
        let vacia = modelsRequest(endpoint: OpenAIEndpoint(baseURL: "http://localhost:1234/v1", model: "", apiKey: { "  " }))

        #expect(conClave.headers["Authorization"] == "Bearer sk-1")
        #expect(conClave.method == "GET")
        #expect(sinClave.headers["Authorization"] == nil)
        #expect(vacia.headers["Authorization"] == nil)
    }

    @Test("la respuesta del chat se lee aunque venga envuelta en un bloque de codigo o con etiquetas en una cadena")
    func respuestaDeChat() throws {
        let envuelta = chat("```json\n{\"title\":\"Backups\",\"summary\":\"Se habló de MinIO.\",\"tags\":[\"backups\"]}\n```")
        let enCadena = chat(#"{"title":"T","summary":"R","tags":"backups, minio"}"#)

        #expect(try digest(fromChat: Data(envuelta.utf8)) == Digest(title: "Backups", summary: "Se habló de MinIO.", tags: ["backups"]))
        #expect(try digest(fromChat: Data(enCadena.utf8)).tags == ["backups", "minio"])
    }

    @Test("una respuesta sin titulo ni resumen, o sin texto, es ilegible")
    func respuestaIlegible() {
        #expect(throws: RemoteAPIError.self) { try digest(fromChat: Data(chat(#"{"tags":["x"]}"#).utf8)) }
        #expect(throws: RemoteAPIError.self) { try digest(fromChat: Data(chat("no es json").utf8)) }
        #expect(throws: RemoteAPIError.self) { try digest(fromChat: Data(#"{"choices":[]}"#.utf8)) }
    }

    @Test("los modelos se leen de /models y salen ordenados")
    func modelos() throws {
        let cuerpo = #"{"object":"list","data":[{"id":"whisper-1"},{"id":"gpt-b"},{"id":"gpt-a"}]}"#

        #expect(try modelIDs(from: Data(cuerpo.utf8)) == ["gpt-a", "gpt-b", "whisper-1"])
        #expect(modelsRequest(endpoint: servicio).url == "https://api.openai.com/v1/models")
    }
}

@Suite("API compatible con OpenAI: errores")
struct ErroresRemotosTests {
    @Test("cada estado se traduce a un motivo que se entiende, con el mensaje del servicio")
    func estados() {
        let cuerpo = Data(errorDeAPI("Incorrect API key provided").utf8)

        #expect(remoteError(status: 401, body: cuerpo) == .unauthorized("Incorrect API key provided"))
        #expect(remoteError(status: 403, body: cuerpo) == .unauthorized("Incorrect API key provided"))
        #expect(remoteError(status: 404, body: cuerpo) == .notFound("Incorrect API key provided"))
        #expect(remoteError(status: 413, body: Data()) == .tooLarge)
        #expect(remoteError(status: 429, body: cuerpo) == .rateLimited("Incorrect API key provided"))
        #expect(remoteError(status: 503, body: Data("caído".utf8)) == .server(status: 503, message: "caído"))
        #expect(remoteError(status: 400, body: cuerpo) == .rejected(status: 400, message: "Incorrect API key provided"))
        #expect(RemoteAPIError.unauthorized("x").message.contains("clave"))
    }

    @Test("lo que afecta a todas las notas se distingue de lo que solo afecta a una")
    func alcance() {
        #expect(RemoteAPIError.unauthorized("").blocksEveryRecording)
        #expect(RemoteAPIError.notFound("").blocksEveryRecording)
        #expect(RemoteAPIError.rateLimited("").blocksEveryRecording)
        #expect(RemoteAPIError.server(status: 502, message: "").blocksEveryRecording)
        #expect(RemoteAPIError.transport("").blocksEveryRecording)
        #expect(!RemoteAPIError.tooLarge.blocksEveryRecording)
        #expect(!RemoteAPIError.rejected(status: 400, message: "").blocksEveryRecording)
        #expect(!RemoteAPIError.malformed("").blocksEveryRecording)
    }
}

@Suite("API compatible con OpenAI: URL del servicio")
struct URLRemotaTests {
    @Test("se aceptan https y, dentro de casa o de la tailnet, tambien http")
    func validas() {
        for url in [
            "https://api.openai.com/v1", "http://localhost:1234/v1", "http://127.0.0.1:11434/v1",
            "http://192.168.1.20:8000/v1", "http://10.0.0.5/v1", "http://172.20.1.1/v1",
            "http://100.101.2.3:8000/v1", "http://ollama.local:11434/v1", "http://[::1]:8080/v1",
        ] {
            #expect(remoteURLProblem(url) == nil, "\(url)")
        }
    }

    @Test("lo que no es una URL de API se explica")
    func invalidas() {
        #expect(remoteURLProblem("  ") == "Escribe la URL de la API.")
        #expect(remoteURLProblem("api.openai.com/v1") == "La URL tiene que empezar por http:// o https://.")
        #expect(remoteURLProblem("ftp://x.com/v1") == "La URL tiene que empezar por http:// o https://.")
        #expect(remoteURLProblem("http://api.example.com/v1") == "Usa https:// para un servicio fuera de tu red.")
        #expect(remoteURLProblem("http://172.32.0.1/v1") == "Usa https:// para un servicio fuera de tu red.")
        #expect(remoteURLProblem("https://yo:secreto@x.com/v1") == "La URL no puede llevar usuario, contraseña ni parámetros.")
        #expect(remoteURLProblem("https://x.com/v1?key=1") == "La URL no puede llevar usuario, contraseña ni parámetros.")
    }
}
