import Testing

@testable import EscribaCore

@Suite("Datos de la nota: JSON que conserva el orden")
struct DatosDeLaNotaTests {
    @Test("lee un objeto anidado y conserva el orden de las claves")
    func conservaOrden() throws {
        let datos = try parseData(#"{"urgente":true,"cliente":"Acme","tareas":["llamar","enviar"],"n":3,"x":null}"#)

        guard case .object(let campos) = datos else {
            Issue.record("no es un objeto")
            return
        }
        #expect(campos.map(\.name) == ["urgente", "cliente", "tareas", "n", "x"])
        #expect(datos["cliente"] == .string("Acme"))
        #expect(datos["tareas"] == .array([.string("llamar"), .string("enviar")]))
        #expect(datos["n"] == .number(3))
        #expect(datos["x"] == .null)
        #expect(datos["falta"] == nil)
    }

    @Test("escribe JSON compacto en el mismo orden y lo vuelve a leer igual")
    func idaYVuelta() throws {
        let texto = #"{"b":1,"a":[1.5,-2,true,false,null],"c":{"z":"\"hola\"\n","y":"ñandú 🎙"}}"#
        let datos = try parseData(texto)

        #expect(dataText(datos) == texto)
        #expect(try parseData(dataText(datos)) == datos)
    }

    @Test("entiende escapes, unicode y números con exponente")
    func escapes() throws {
        #expect(try parseData(#""año 🎙 \t\/""#) == .string("año 🎙 \t/"))
        #expect(try parseData("1e3") == .number(1000))
        #expect(try parseData(" -0.25 ") == .number(-0.25))
        #expect(dataText(.number(1000)) == "1000")
        #expect(dataText(.number(0.1)) == "0.1")
        #expect(dataText(.string("\u{1}")) == #""\u0001""#)
    }

    @Test("un sustituto suelto en un escape \\u no tumba nada: sale el carácter de reemplazo")
    func sustitutoSuelto() throws {
        #expect(try parseData(#""\ud83dA""#) == .string("\u{FFFD}A"))
        #expect(try parseData(#""\ud83d\u0041""#) == .string("\u{FFFD}A"))
        #expect(try parseData(#""\udc00x""#) == .string("\u{FFFD}x"))
    }

    @Test("un anidamiento absurdo es un error, no un desbordamiento de pila")
    func profundidad() {
        let hondo = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: DataParseError.self) { try parseData(hondo) }
        let razonable = String(repeating: "[", count: 60) + String(repeating: "]", count: 60)
        #expect(throws: Never.self) { try parseData(razonable) }
    }

    @Test("rechaza lo que no es JSON")
    func rechaza() {
        for roto in ["", "{", #"{"a":}"#, "[1,]", "tru", #"{"a":1} x"#, #""sin cerrar"#, "{a:1}"] {
            #expect(throws: DataParseError.self, "\(roto)") { try parseData(roto) }
        }
    }

    @Test("los datos de una nota son un objeto o nada")
    func soloObjetos() throws {
        #expect(try noteData(#"{"a":1}"#) == .object([DataField(name: "a", value: .number(1))]))
        #expect(try noteData("null") == nil)
        #expect(throws: NoteDataProblem.notAnObject) { try noteData("[1,2]") }
        #expect(throws: NoteDataProblem.notAnObject) { try noteData(#""texto""#) }
        let enorme = #"{"a":""# + String(repeating: "x", count: maximumNoteDataBytes) + #""}"#
        #expect(throws: NoteDataProblem.tooLarge(maximumNoteDataBytes + 8)) { try noteData(enorme) }
    }

    @Test("el detalle pinta cada campo en su orden, con listas, grupos y sí o no, y se salta lo vacío")
    func filas() throws {
        let datos = try parseData(
            #"{"cliente":"Acme","urgente":false,"importe":12.5,"personas":3,"tareas":["llamar",null],"#
                + #""contacto":{"nombre":"Ana","email":null},"vacia":[],"nada":{},"reunion":null,"#
                + #""sinNada":{"a":null,"b":[]},"pasos":[{"hecho":true}]}"#)

        #expect(dataRows(datos) == [
            DataRow(label: "cliente", depth: 0, value: .text("Acme")),
            DataRow(label: "urgente", depth: 0, value: .text("no")),
            DataRow(label: "importe", depth: 0, value: .text("12,5")),
            DataRow(label: "personas", depth: 0, value: .text("3")),
            DataRow(label: "tareas", depth: 0, value: .list(["llamar", "—"])),
            DataRow(label: "contacto", depth: 0, value: .group),
            DataRow(label: "nombre", depth: 1, value: .text("Ana")),
            DataRow(label: "pasos 1", depth: 0, value: .group),
            DataRow(label: "hecho", depth: 1, value: .text("sí")),
        ])
    }

    @Test("unos datos sin nada que enseñar no dan ninguna fila")
    func sinNada() throws {
        #expect(dataRows(try parseData(#"{"a":null,"b":[],"c":{"d":null}}"#)).isEmpty)
    }

    @Test("con el esquema guardado, cada campo usa su title de Zod, también dentro de nulos, grupos y listas")
    func titulos() throws {
        let esquema = try parseData(#"""
            {"type":"object","properties":{
              "enUnaFrase":{"type":"string","title":"En una frase"},
              "reunion":{"anyOf":[{"type":"object","properties":{"tareas":{"type":"array","items":{"type":"object","properties":{"que":{"type":"string","title":"Qué"}}},"title":"Tareas"}}},{"type":"null"}],"title":"Reunión"},
              "idea":{"anyOf":[{"type":"object","properties":{"titulo":{"type":"string"}},"title":"Idea"},{"type":"null"}]},
              "sin":{"type":"string"}}}
            """#)
        let datos = try parseData(
            #"{"enUnaFrase":"Hola","reunion":{"tareas":[{"que":"llamar"}]},"idea":{"titulo":"T"},"sin":"x","extra":1}"#)

        #expect(dataRows(datos, schema: esquema) == [
            DataRow(label: "En una frase", depth: 0, value: .text("Hola")),
            DataRow(label: "Reunión", depth: 0, value: .group),
            DataRow(label: "Tareas 1", depth: 1, value: .group),
            DataRow(label: "Qué", depth: 2, value: .text("llamar")),
            DataRow(label: "Idea", depth: 0, value: .group),
            DataRow(label: "titulo", depth: 1, value: .text("T")),
            DataRow(label: "sin", depth: 0, value: .text("x")),
            DataRow(label: "extra", depth: 0, value: .text("1")),
        ])
    }

    @Test("el texto legible de unos datos es JSON con sangría y en su orden")
    func legible() throws {
        let datos = try parseData(#"{"b":[1,2],"a":{"c":"x"},"v":{},"l":[]}"#)

        #expect(dataText(datos, pretty: true) == """
            {
              "b": [
                1,
                2
              ],
              "a": {
                "c": "x"
              },
              "v": {},
              "l": []
            }
            """)
    }
}
