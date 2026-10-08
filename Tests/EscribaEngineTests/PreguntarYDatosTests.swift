import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let objetivo = RecipeTarget(
    key: "x", name: "X", kind: .code, package: RecipePackage(key: "x", source: "", fingerprint: "f"))

private let esquema = #"""
{"type":"object","properties":{"cliente":{"type":["string","null"]},"tareas":{"type":"array","items":{"type":"string"}}},"required":["cliente","tareas"],"additionalProperties":false}
"""#

private func preguntador(
    _ nombre: String = "Falso", capacidad: Int = 1000, disponible: SummaryAvailability = .ready,
    llamadas: Trace<AnswerRequest> = Trace(), responde: @escaping @Sendable (AnswerRequest) -> String
) -> Asker {
    Asker(name: nombre, capacity: capacidad, availability: { disponible }) { peticion throws(AnswerError) in
        llamadas.append(peticion)
        return responde(peticion)
    }
}

private func ejecutar(
    memoria: MemoryNotes = MemoryNotes(), preguntador: Asker? = nil, dryRun: Bool = false,
    _ flujo: @escaping @Sendable (RecipeBridge) async throws -> Void
) async -> (Result<(transcript: Transcript, output: URL), any Error>, RecipeTrace) {
    let recipe = Recipe(
        shelf: .only(objetivo), runtime: RecipeRuntime(name: "falso") { _, bridge in try await flujo(bridge) },
        publishers: [:],
        catalog: RecipeCatalog(asker: { _, llm in
            guard llm == nil || llm == "falso" else { throw RecipeError.failed("no hay ningún LLM «\(llm ?? "")»") }
            guard let preguntador else { throw RecipeError.unavailable("sin LLM") }
            return preguntador
        }))
    return await runRecipe(
        objetivo, of: recipe, on: recording("a"),
        backend: backend { _ in Transcript(text: "hola, soy Ana de Acme") }, enrich: nil, memory: memoria.port,
        save: { _ in URL(fileURLWithPath: "/salida/a") }, dryRun: dryRun)
}

@Suite("Preguntar a un LLM con respuesta estructurada")
struct PreguntarTests {
    @Test("con esquema devuelve el objeto en el orden del esquema, con los nulos que falten, y lo anota en la traza")
    func conEsquema() async throws {
        let llamadas = Trace<AnswerRequest>()
        let respuesta = Mutex<String?>(nil)
        let (resultado, traza) = await ejecutar(
            preguntador: preguntador(llamadas: llamadas) { _ in "Aquí va:\n```json\n{\"tareas\": [\"llamar\"]}\n```" }
        ) { escriba in
            let nota = try await escriba.transcribe(RecipeTranscription())
            let texto = try await escriba.ask(
                RecipeQuestion(instructions: "Saca el cliente", input: nota.transcript.text), esquema)
            respuesta.withLock { $0 = texto }
            try await escriba.save()
        }

        _ = try resultado.get()
        #expect(respuesta.withLock { $0 } == #"{"cliente":null,"tareas":["llamar"]}"#)
        #expect(llamadas.values.first?.instructions == "Saca el cliente")
        #expect(llamadas.values.first?.input == "hola, soy Ana de Acme")
        #expect(llamadas.values.first?.schema == AnswerSchema(.object([
            AnswerProperty(name: "cliente", schema: AnswerSchema(.string(choices: nil), nullable: true)),
            AnswerProperty(name: "tareas", schema: AnswerSchema(.array(AnswerSchema(.string(choices: nil)), minimum: nil, maximum: nil))),
        ])))
        #expect(traza.steps.map(\.title).contains("preguntar · Falso"))
    }

    @Test("sin esquema devuelve el texto de la respuesta como cadena JSON")
    func sinEsquema() async throws {
        let respuesta = Mutex<String?>(nil)
        let (resultado, _) = await ejecutar(preguntador: preguntador { _ in "  Acme  \n" }) { escriba in
            let texto = try await escriba.ask(RecipeQuestion(input: "¿quién?"), nil)
            respuesta.withLock { $0 = texto }
            _ = try await escriba.transcribe(RecipeTranscription())
            try await escriba.save()
        }

        _ = try resultado.get()
        #expect(respuesta.withLock { $0 } == #""Acme""#)
    }

    @Test("una entrada que no cabe en el LLM es un error claro y no llega a preguntar")
    func noCabe() async throws {
        let llamadas = Trace<AnswerRequest>()
        let (resultado, traza) = await ejecutar(
            preguntador: preguntador("Apple Intelligence", capacidad: 10, llamadas: llamadas) { _ in "{}" }
        ) { escriba in
            _ = try await escriba.ask(RecipeQuestion(input: String(repeating: "a", count: 11)), esquema)
        }

        #expect(throws: AnswerError.tooLong(model: "Apple Intelligence", characters: 11, capacity: 10)) {
            try resultado.get()
        }
        #expect(llamadas.values.isEmpty)
        #expect(traza.steps.last?.capability == "preguntar")
        #expect(traza.steps.last?.error?.contains("Apple Intelligence admite 10") == true)
    }

    @Test("un LLM apagado, uno que no existe o un esquema que no se puede traducir fallan antes de preguntar")
    func fallaAntes() async throws {
        let llamadas = Trace<AnswerRequest>()
        let apagado = preguntador(disponible: .unavailable("el modelo se está descargando"), llamadas: llamadas) { _ in "{}" }

        let (sinModelo, _) = await ejecutar(preguntador: apagado) { escriba in
            _ = try await escriba.ask(RecipeQuestion(input: "x"), esquema)
        }
        #expect(throws: AnswerError.unavailable("el modelo se está descargando")) { try sinModelo.get() }

        let (desconocido, traza) = await ejecutar(preguntador: apagado) { escriba in
            _ = try await escriba.ask(RecipeQuestion(llm: "gpt", input: "x"), esquema)
        }
        #expect(throws: RecipeError.failed("no hay ningún LLM «gpt»")) { try desconocido.get() }
        #expect(traza.steps.map(\.title) == ["preguntar · gpt"])

        let (registro, _) = await ejecutar(preguntador: apagado) { escriba in
            _ = try await escriba.ask(
                RecipeQuestion(input: "x"),
                #"{"type":"object","properties":{"m":{"type":"object","additionalProperties":{"type":"number"}}},"required":["m"]}"#)
        }
        #expect(throws: AnswerSchemaProblem.unsupported(path: "m", what: "un registro de claves libres (z.record)")) {
            try registro.get()
        }
        #expect(llamadas.values.isEmpty)
    }

    @Test("una respuesta sin objeto JSON no llega a la receta a medias")
    func malformada() async throws {
        let (resultado, _) = await ejecutar(preguntador: preguntador { _ in "no lo sé" }) { escriba in
            _ = try await escriba.ask(RecipeQuestion(input: "x"), esquema)
        }

        #expect {
            try resultado.get()
        } throws: { error in
            guard case AnswerError.malformed = error else { return false }
            return true
        }
    }

    @Test("la misma pregunta sobre la misma versión se recuerda; otra pregunta, no")
    func recuerda() async throws {
        let memoria = MemoryNotes()
        let llamadas = Trace<AnswerRequest>()
        let falso = preguntador(llamadas: llamadas) { _ in #"{"cliente":"Acme","tareas":[]}"# }
        let flujo: @Sendable (RecipeBridge) async throws -> Void = { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            _ = try await escriba.ask(RecipeQuestion(input: "¿cliente?"), esquema)
            try await escriba.save()
        }

        _ = await ejecutar(memoria: memoria, preguntador: falso, flujo)
        let (_, segunda) = await ejecutar(memoria: memoria, preguntador: falso, flujo)
        _ = await ejecutar(memoria: memoria, preguntador: falso) { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            _ = try await escriba.ask(RecipeQuestion(input: "¿tareas?"), esquema)
            try await escriba.save()
        }

        #expect(llamadas.values.map(\.input) == ["¿cliente?", "¿tareas?"])
        #expect(segunda.steps.map(\.title).contains("preguntar · Falso · recordado"))
        #expect(memoria.answerCount == 2)
    }

    @Test("probar una receta aprovecha las respuestas guardadas pero no guarda las nuevas")
    func probarNoGuarda() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "guardada"))
        let llamadas = Trace<AnswerRequest>()

        _ = await ejecutar(memoria: memoria, preguntador: preguntador(llamadas: llamadas) { _ in "{}" }, dryRun: true) {
            escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            _ = try await escriba.ask(RecipeQuestion(input: "x"), esquema)
            try await escriba.save()
        }

        #expect(llamadas.values.count == 1)
        #expect(memoria.answerCount == 0)
    }
}

@Suite("Datos propios de la nota, por versión")
struct DatosPorVersionTests {
    @Test("guardar con datos los deja en la versión, en la traza y en la nota que vuelve a pedirse")
    func guarda() async throws {
        let memoria = MemoryNotes()
        let vista = Mutex<RecipeNote?>(nil)
        let (resultado, traza) = await ejecutar(memoria: memoria) { escriba in
            let nota = try await escriba.transcribe(RecipeTranscription())
            #expect(nota.data == nil)
            try await escriba.saveData(#"{"urgente":true,"cliente":"Acme"}"#, nil)
            let otra = try await escriba.transcribe(RecipeTranscription())
            vista.withLock { $0 = otra }
        }

        _ = try resultado.get()
        let datos = try parseData(#"{"urgente":true,"cliente":"Acme"}"#)
        #expect(memoria.data("a") == datos)
        #expect(vista.withLock { $0?.data } == datos)
        #expect(traza.data == #"{"urgente":true,"cliente":"Acme"}"#)
        #expect(memoria.steps.values.contains("guarda datos v1"))
    }

    @Test("guardar sin datos no toca los que ya tenía la versión, y null los quita")
    func conserva() async throws {
        let memoria = MemoryNotes()
        let previos = try parseData(#"{"a":1}"#)
        let version = memoria.remember("a", Transcript(text: "hola"))
        try await memoria.port.keepData(recording("a"), version, previos, nil)

        let (_, traza) = await ejecutar(memoria: memoria) { escriba in
            let nota = try await escriba.transcribe(RecipeTranscription())
            #expect(nota.data == previos)
            try await escriba.save()
        }
        #expect(memoria.data("a") == previos)
        #expect(memoria.steps.values.filter { $0 == "guarda datos v\(version)" }.count == 1)
        #expect(traza.data == #"{"a":1}"#)

        _ = await ejecutar(memoria: memoria) { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            try await escriba.saveData("null", nil)
        }
        #expect(memoria.data("a") == nil)
    }

    @Test("unos datos que no son un objeto no se guardan y la traza dice por qué")
    func noObjeto() async throws {
        let memoria = MemoryNotes()
        let (resultado, traza) = await ejecutar(memoria: memoria) { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            try await escriba.saveData("[1,2]", nil)
        }

        #expect(throws: NoteDataProblem.notAnObject) { try resultado.get() }
        #expect(traza.steps.last?.title == "guardar")
        #expect(traza.steps.last?.error == "\(NoteDataProblem.notAnObject)")
        #expect(memoria.data("a") == nil)
    }

    @Test("el esquema con el que se guardaron los datos viaja a la memoria y a la traza")
    func esquema() async throws {
        let memoria = MemoryNotes()
        let esquemas = Trace<String?>()
        var puerto = memoria.port
        let guardar = puerto.keepData
        puerto.keepData = { grabacion, version, datos, esquema in
            esquemas.append(esquema.map { dataText($0) })
            try await guardar(grabacion, version, datos, esquema)
        }
        let recipe = Recipe(
            shelf: .only(objetivo),
            runtime: RecipeRuntime(name: "falso") { _, escriba in
                _ = try await escriba.transcribe(RecipeTranscription())
                try await escriba.saveData(#"{"a":1}"#, #"{"type":"object","properties":{"a":{"type":"number","title":"A"}}}"#)
            },
            publishers: [:])

        let (_, traza) = await runRecipe(
            objetivo, of: recipe, on: recording("a"), backend: backend { _ in Transcript(text: "hola") }, enrich: nil,
            memory: puerto, save: { _ in URL(fileURLWithPath: "/salida/a") })

        #expect(esquemas.values == [#"{"type":"object","properties":{"a":{"type":"number","title":"A"}}}"#])
        #expect(traza.dataSchema == #"{"type":"object","properties":{"a":{"type":"number","title":"A"}}}"#)
    }

    @Test("al probar, los datos salen en la traza pero no se guardan")
    func probar() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", Transcript(text: "hola"))

        let (_, traza) = await ejecutar(memoria: memoria, dryRun: true) { escriba in
            _ = try await escriba.transcribe(RecipeTranscription())
            try await escriba.saveData(#"{"b":2}"#, nil)
        }

        #expect(traza.data == #"{"b":2}"#)
        #expect(memoria.data("a") == nil)
    }
}
