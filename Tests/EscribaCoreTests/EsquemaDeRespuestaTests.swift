import Testing

@testable import EscribaCore

private let reunion = #"""
{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"cliente":{"description":"La empresa","type":["string","null"]},"tareas":{"minItems":1,"maxItems":5,"type":"array","items":{"type":"string"}},"urgente":{"type":"boolean"},"tipo":{"type":"string","enum":["reunion","idea"]},"personas":{"type":"integer","minimum":-9007199254740991,"maximum":9007199254740991},"contacto":{"anyOf":[{"type":"object","properties":{"nombre":{"type":"string"},"email":{"type":"string","format":"email","pattern":"^x$"}},"required":["nombre","email"],"additionalProperties":false},{"type":"null"}]},"prioridad":{"anyOf":[{"type":"string","const":"alta"},{"type":"string","const":"baja"}]},"importe":{"type":"number"}},"required":["cliente","tareas","urgente","tipo","contacto","prioridad","importe"],"additionalProperties":false,"description":"Datos de la reunión"}
"""#

private func esquema(_ texto: String) throws -> AnswerSchema {
    try answerSchema(from: try parseData(texto))
}

@Suite("Esquema de respuesta: lo que Zod exporta, traducido a lo que entienden los LLM")
struct EsquemaDeRespuestaTests {
    @Test("lee el JSON Schema de Zod con nulos, enumerados, literales, listas y objetos anidados, en su orden")
    func leeZod() throws {
        let leido = try esquema(reunion)
        let texto = AnswerSchema(.string(choices: nil))

        #expect(leido == AnswerSchema(
            .object([
                AnswerProperty(name: "cliente", schema: AnswerSchema(.string(choices: nil), description: "La empresa", nullable: true)),
                AnswerProperty(name: "tareas", schema: AnswerSchema(.array(texto, minimum: 1, maximum: 5))),
                AnswerProperty(name: "urgente", schema: AnswerSchema(.boolean)),
                AnswerProperty(name: "tipo", schema: AnswerSchema(.string(choices: ["reunion", "idea"]))),
                AnswerProperty(name: "personas", schema: AnswerSchema(.integer), required: false),
                AnswerProperty(
                    name: "contacto",
                    schema: AnswerSchema(
                        .object([
                            AnswerProperty(name: "nombre", schema: texto),
                            AnswerProperty(name: "email", schema: texto),
                        ]),
                        nullable: true)),
                AnswerProperty(name: "prioridad", schema: AnswerSchema(.string(choices: ["alta", "baja"]))),
                AnswerProperty(name: "importe", schema: AnswerSchema(.number)),
            ]),
            description: "Datos de la reunión"))
    }

    @Test("lo que ningún LLM entiende se rechaza diciendo dónde está y qué usar")
    func rechaza() {
        let casos: [(String, AnswerSchemaProblem)] = [
            (
                #"{"type":"object","properties":{"m":{"type":"object","propertyNames":{"type":"string"},"additionalProperties":{"type":"number"}}},"required":["m"]}"#,
                .unsupported(path: "m", what: "un registro de claves libres (z.record)")
            ),
            (
                #"{"type":"object","properties":{"u":{"anyOf":[{"type":"object","properties":{"a":{"type":"string"}}},{"type":"object","properties":{"b":{"type":"number"}}}]}},"required":["u"]}"#,
                .unsupported(path: "u", what: "una unión de tipos distintos")
            ),
            (
                #"{"type":"object","properties":{"t":{"type":"array","prefixItems":[{"type":"string"}],"items":false}},"required":["t"]}"#,
                .unsupported(path: "t", what: "una tupla (z.tuple)")
            ),
            (
                ##"{"type":"object","properties":{"hijos":{"type":"array","items":{"$ref":"#"}}},"required":["hijos"]}"##,
                .unsupported(path: "hijos[]", what: "un esquema recursivo ($ref)")
            ),
            (
                #"{"type":"object","properties":{"x":{"type":["string","number"]}},"required":["x"]}"#,
                .unsupported(path: "x", what: "una unión de tipos distintos")
            ),
            (#"{"type":"string"}"#, .notAnObject),
            (#"{"anyOf":[{"type":"object","properties":{}},{"type":"null"}]}"#, .notAnObject),
            (#"[1]"#, .notAnObject),
        ]
        for (texto, problema) in casos {
            #expect(throws: problema, "\(texto)") { try esquema(texto) }
        }
    }

    @Test("el problema se explica en castellano")
    func explica() {
        #expect(
            "\(AnswerSchemaProblem.unsupported(path: "m", what: "un registro de claves libres (z.record)"))"
                == "el esquema usa un registro de claves libres (z.record) en «m», y los LLM no saben responder a eso")
        #expect("\(AnswerSchemaProblem.notAnObject)" == "el esquema de una pregunta tiene que ser un objeto (z.object)")
    }

    @Test("se vuelve a escribir como JSON Schema limpio para la API de OpenAI, en el mismo orden")
    func paraOpenAI() throws {
        let limpio = dataText(jsonSchema(try esquema(reunion)))

        #expect(limpio == #"{"type":"object","description":"Datos de la reunión","properties":{"#
            + #""cliente":{"type":["string","null"],"description":"La empresa"},"#
            + #""tareas":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":5},"#
            + #""urgente":{"type":"boolean"},"#
            + #""tipo":{"type":"string","enum":["reunion","idea"]},"#
            + #""personas":{"type":"integer"},"#
            + #""contacto":{"anyOf":[{"type":"object","properties":{"nombre":{"type":"string"},"email":{"type":"string"}},"required":["nombre","email"],"additionalProperties":false},{"type":"null"}]},"#
            + #""prioridad":{"type":"string","enum":["alta","baja"]},"#
            + #""importe":{"type":"number"}},"#
            + #""required":["cliente","tareas","urgente","tipo","contacto","prioridad","importe"],"additionalProperties":false}"#)
    }

    @Test("un enumerado que admite nulo lleva el nulo también en la lista")
    func enumeradoNulo() throws {
        let leido = try esquema(#"{"type":"object","properties":{"e":{"type":["string","null"],"enum":["a","b",null]}},"required":["e"]}"#)

        #expect(leido == AnswerSchema(.object([
            AnswerProperty(name: "e", schema: AnswerSchema(.string(choices: ["a", "b"]), nullable: true)),
        ])))
        #expect(dataText(jsonSchema(leido)).contains(#""e":{"type":["string","null"],"enum":["a","b",null]}"#))
    }

    @Test("el modo estricto de OpenAI solo vale si todos los campos son obligatorios en todos los niveles")
    func estricto() throws {
        #expect(!isStrict(try esquema(reunion)))
        #expect(isStrict(try esquema(#"{"type":"object","properties":{"a":{"type":"string"},"o":{"type":"object","properties":{"b":{"type":"number"}},"required":["b"]}},"required":["a","o"]}"#)))
        #expect(!isStrict(try esquema(#"{"type":"object","properties":{"a":{"type":"string"},"o":{"type":"object","properties":{"b":{"type":"number"}},"required":[]}},"required":["a","o"]}"#)))
    }

    @Test("los campos que admiten nulo y no llegaron se rellenan con null, en el orden del esquema")
    func rellenaNulos() throws {
        let leido = try esquema(reunion)
        let respuesta = try parseData(#"{"tareas":["a"],"urgente":true,"contacto":{"nombre":"Ana","email":"a@b.c"},"extra":1}"#)

        #expect(dataText(completingNulls(respuesta, for: leido))
            == #"{"cliente":null,"tareas":["a"],"urgente":true,"contacto":{"nombre":"Ana","email":"a@b.c"},"extra":1}"#)
        #expect(completingNulls(.string("x"), for: leido) == .string("x"))
    }

    @Test("del texto de un modelo se saca el objeto JSON aunque venga envuelto")
    func objetoEnElTexto() throws {
        #expect(try answerObject(in: "Claro:\n```json\n{\"a\": {\"b\": 1}}\n```") == .object([
            DataField(name: "a", value: .object([DataField(name: "b", value: .number(1))])),
        ]))
        #expect(throws: DataParseError.self) { try answerObject(in: "no sé") }
    }
}
