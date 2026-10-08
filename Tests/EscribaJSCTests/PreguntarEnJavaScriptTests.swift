import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaJSC

private let esquemaFalso = """
    const Cliente = {
      "~standard": {
        version: 1, vendor: "prueba",
        validate: (v) => typeof v?.cliente === "string"
          ? { value: { cliente: v.cliente.trim() } }
          : { issues: [{ message: "falta el cliente", path: [{ key: "cliente" }] }] },
        jsonSchema: { output: () => ({ type: "object", properties: { cliente: { type: "string" } }, required: ["cliente"] }) },
      },
    }
    """

@Suite("Preguntar y datos desde la receta, en JavaScriptCore")
struct PreguntarEnJavaScriptTests {
    @Test("preguntar manda la pregunta y el JSON Schema del esquema, y devuelve lo que valida el esquema")
    func conEsquema() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete(
                """
                const r = await escriba.preguntar({ esquema: Cliente, entrada: "hola", instrucciones: "di el cliente", llm: "apple" })
                escriba.log(`cliente: [${r.cliente}]`)
                """, antes: esquemaFalso),
            puente(registro, ask: { pregunta, _ in
                #expect(pregunta == RecipeQuestion(llm: "apple", instructions: "di el cliente", input: "hola"))
                return #"{"cliente":" Acme "}"#
            }))

        #expect(registro.values == [
            #"pregunta hola con {"type":"object","properties":{"cliente":{"type":"string"}},"required":["cliente"]}"#,
            "log cliente: [Acme]",
        ])
    }

    @Test("una respuesta que no casa con el esquema es un error que la receta puede recoger")
    func noCasa() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete(
                """
                try {
                  await escriba.preguntar({ esquema: Cliente, entrada: "hola" })
                } catch (e) {
                  escriba.log(`${e.codigo}: ${e.message}`)
                }
                """, antes: esquemaFalso),
            puente(registro, ask: { _, _ in #"{"otro":1}"# }))

        #expect(registro.values.last == "log fallo: la respuesta del LLM no casa con el esquema: cliente: falta el cliente")
    }

    @Test("sin esquema devuelve texto; con algo que no es un esquema de Zod, un error claro")
    func sinEsquema() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                const texto = await escriba.preguntar({ entrada: "hola" })
                escriba.log(`${typeof texto}: ${texto}`)
                try {
                  await escriba.preguntar({ entrada: "hola", esquema: { type: "object" } })
                } catch (e) {
                  escriba.log(e.message)
                }
                """),
            puente(registro, ask: { _, _ in #""Acme""# }))

        #expect(registro.values == [
            "pregunta hola", "log string: Acme", "log el esquema de preguntar tiene que ser de Zod: z.object({ … })",
        ])
    }

    @Test("un LLM que no está disponible llega con codigo no-disponible")
    func noDisponible() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                try {
                  await escriba.preguntar({ entrada: "hola" })
                } catch (e) {
                  escriba.log(e.codigo)
                }
                """),
            puente(registro, ask: { _, _ in throw AnswerError.unavailable("descargando") }))

        #expect(registro.values.last == "log no-disponible")
    }

    @Test("la nota trae sus datos; guardar sin cambiarlos no los manda, cambiarlos sí")
    func datos() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                const nota = await escriba.transcribir(audio)
                escriba.log(JSON.stringify(nota.datos))
                await nota.guardar()
                nota.datos.urgente = false
                await nota.guardar()
                await nota.guardar({ datos: { b: 1 } })
                await nota.guardar({ datos: null })
                """),
            puente(registro, transcribe: { _ in nota(datos: try parseData(#"{"urgente":true,"a":[1]}"#)) }))

        #expect(registro.values == [
            "transcribe", #"log {"urgente":true,"a":[1]}"#, "guarda", #"guarda {"urgente":false,"a":[1]}"#,
            #"guarda {"b":1}"#, "guarda null",
        ])
    }

    @Test("si la receta declara datos, se validan al guardar y no se manda nada que no case")
    func datosValidados() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete(
                """
                const nota = await escriba.transcribir(audio)
                await nota.guardar({ datos: { cliente: "  Acme " } })
                escriba.log(nota.datos.cliente)
                try {
                  await nota.guardar({ datos: { nada: 1 } })
                } catch (e) {
                  escriba.log(e.message)
                }
                """, antes: esquemaFalso, datos: "Cliente"),
            puente(registro))

        #expect(registro.values == [
            "transcribe",
            #"guarda {"cliente":"Acme"} según {"type":"object","properties":{"cliente":{"type":"string"}},"required":["cliente"]}"#,
            "log Acme",
            "log los datos de la nota no casan con el esquema: cliente: falta el cliente",
        ])
    }

    @Test("una receta cuyo datos no es un esquema no carga")
    func datosQueNoSonEsquema() async throws {
        await #expect(throws: RecipeError.invalidPackage("receta.datos tiene que ser un esquema de Zod: z.object({ … })")) {
            try await ejecutar(paquete("", datos: "{ a: 1 }"), puente(Registro()))
        }
    }
}
