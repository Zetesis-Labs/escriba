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

    @Test("el detalle pinta cada campo en su orden, con listas, grupos y sí o no")
    func filas() throws {
        let datos = try parseData(
            #"{"cliente":"Acme","urgente":false,"importe":12.5,"personas":3,"tareas":["llamar","enviar"],"#
                + #""contacto":{"nombre":"Ana","email":null},"vacia":[],"pasos":[{"hecho":true}]}"#)

        #expect(dataRows(datos) == [
            DataRow(label: "cliente", depth: 0, value: .text("Acme")),
            DataRow(label: "urgente", depth: 0, value: .text("no")),
            DataRow(label: "importe", depth: 0, value: .text("12,5")),
            DataRow(label: "personas", depth: 0, value: .text("3")),
            DataRow(label: "tareas", depth: 0, value: .list(["llamar", "enviar"])),
            DataRow(label: "contacto", depth: 0, value: .group),
            DataRow(label: "nombre", depth: 1, value: .text("Ana")),
            DataRow(label: "email", depth: 1, value: .text("—")),
            DataRow(label: "vacia", depth: 0, value: .text("—")),
            DataRow(label: "pasos 1", depth: 0, value: .group),
            DataRow(label: "hecho", depth: 1, value: .text("sí")),
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
