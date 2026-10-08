import Foundation
import Testing
import EscribaCore
import EscribaEngine

@testable import EscribaOpenAI

private let esquema = AnswerSchema(.object([
    AnswerProperty(name: "tareas", schema: AnswerSchema(.array(AnswerSchema(.string(choices: nil)), minimum: nil, maximum: nil))),
    AnswerProperty(name: "cliente", schema: AnswerSchema(.string(choices: nil), nullable: true)),
]))

private func preguntador(_ servidor: ServidorFalso) -> Asker {
    openAIAsker(
        name: "OpenAI", endpoint: OpenAIEndpoint(baseURL: "https://api.openai.com/v1", model: "gpt-x", apiKey: { "sk-1" }),
        transport: servidor.transporte)
}

@Suite("Preguntar a una API compatible con OpenAI")
struct PreguntarRemotoTests {
    @Test("pide la respuesta con json_schema, en el orden del esquema y estricto si todo es obligatorio")
    func conEsquema() async throws {
        let servidor = ServidorFalso(json: chat(#"{"tareas":["llamar"],"cliente":"Acme"}"#))

        let respuesta = try await preguntador(servidor).answer(
            AnswerRequest(instructions: "Saca las tareas", input: "Hay que llamar a Acme", schema: esquema))

        #expect(respuesta == (try parseData(#"{"tareas":["llamar"],"cliente":"Acme"}"#)))
        #expect(servidor.peticiones.first?.url == "https://api.openai.com/v1/chat/completions")
        #expect(servidor.peticiones.first?.headers["Authorization"] == "Bearer sk-1")
        #expect(texto(servidor.peticiones.first?.body) == #"{"model":"gpt-x","messages":["#
            + #"{"role":"system","content":"Saca las tareas"},{"role":"user","content":"Hay que llamar a Acme"}],"#
            + #""response_format":{"type":"json_schema","json_schema":{"name":"respuesta","strict":true,"schema":"#
            + dataText(jsonSchema(esquema)) + "}}}")
    }

    @Test("si el servicio no admite esquemas, repite pidiendo un objeto JSON con el esquema en las instrucciones")
    func sinEsquemas() async throws {
        let servidor = ServidorFalso([
            respuesta(400, errorDeAPI("Invalid parameter: 'response_format' of type 'json_schema' is not supported with this model.")),
            respuesta(200, chat(#"{"tareas":[]}"#)),
        ])

        let respuesta = try await preguntador(servidor).answer(AnswerRequest(instructions: nil, input: "x", schema: esquema))

        #expect(respuesta == (try parseData(#"{"tareas":[],"cliente":null}"#)))
        #expect(servidor.peticiones.count == 2)
        let segunda = texto(servidor.peticiones.last?.body)
        #expect(segunda.contains(#""response_format":{"type":"json_object"}"#))
        #expect(segunda.contains("Devuelve solo un objeto JSON que cumpla este esquema: " + dataText(jsonSchema(esquema))
            .replacingOccurrences(of: "\"", with: "\\\"")))
    }

    @Test("sin esquema pregunta en texto libre y devuelve el texto")
    func sinEsquema() async throws {
        let servidor = ServidorFalso(json: chat(" Acme. "))

        let respuesta = try await preguntador(servidor).answer(AnswerRequest(instructions: nil, input: "¿quién?", schema: nil))

        #expect(respuesta == .string("Acme."))
        #expect(texto(servidor.peticiones.first?.body) == #"{"model":"gpt-x","messages":[{"role":"user","content":"¿quién?"}]}"#)
    }

    @Test("un fallo que afecta a todas las notas es no disponible; uno de esta pregunta, un fallo")
    func fallos() async throws {
        await #expect {
            _ = try await preguntador(ServidorFalso([respuesta(401, errorDeAPI("bad key"))]))
                .answer(AnswerRequest(instructions: nil, input: "x", schema: esquema))
        } throws: { error in
            guard case AnswerError.unavailable = error else { return false }
            return true
        }
        await #expect {
            _ = try await preguntador(ServidorFalso([respuesta(400, errorDeAPI("context too long"))]))
                .answer(AnswerRequest(instructions: nil, input: "x", schema: esquema))
        } throws: { error in
            guard case AnswerError.failed = error else { return false }
            return true
        }
    }
}
