import Foundation
import Testing
import EscribaCore

@testable import EscribaPluginKit

@Suite("Contrato de los plugins")
struct ContratoTests {
    @Test("una nota viaja al plugin y vuelve igual")
    func notaIdaYVuelta() throws {
        let nota = sampleNote(recordedAt: Date(timeIntervalSince1970: 1_791_219_600))

        let data = try pluginJSONEncoder().encode(PluginNote(nota))
        let vuelta = try pluginJSONDecoder().decode(PluginNote.self, from: data).note

        #expect(vuelta == nota)
    }

    @Test("una nota sin segmentos conserva su texto")
    func soloTexto() throws {
        let nota = Note(
            recording: Recording(url: URL(fileURLWithPath: "/a.m4a"), startedAt: Date(timeIntervalSince1970: 0), key: "a"),
            transcript: Transcript(text: "Hola"))

        #expect(PluginNote(nota).note == nota)
    }

    @Test("peticion, respuesta y formulario se serializan y vuelven iguales")
    func idaYVuelta() throws {
        let peticion = PluginRequest(
            command: .action, config: .object(["folder": .string("/x")]), state: .object(["n": .number(1)]),
            action: "addDocument", timeZone: "UTC")
        #expect(try pluginJSONDecoder().decode(PluginRequest.self, from: try pluginJSONEncoder().encode(peticion)) == peticion)

        let formulario = PluginForm(
            items: [
                .section("Documentos", footer: "pie", [
                    .tabs([FormTab(id: "d1", label: "Nota", items: [
                        .row([.label("type", width: 130, monospaced: true), .template("documents/0/properties/0/value", context: .property, links: [FormLink(id: "d1", name: "Nota")], current: "d1")]),
                        .button("Quitar", action: "removeProperty/d1/p1", symbol: "xmark.circle", enabled: false),
                    ])], addAction: "addDocument", removeAction: "removeDocument"),
                    .choice("sourceID", label: "Guardar en", options: [FormOption(id: "a", label: "A")]),
                    .preview("---\ntype: nota", label: "notas/a.md"),
                ]),
            ], problem: "Elige la carpeta.")
        let respuesta = PluginResponse(form: formulario, config: .object(["a": .array([.bool(true), .null])]))
        #expect(try pluginJSONDecoder().decode(PluginResponse.self, from: try pluginJSONEncoder().encode(respuesta)) == respuesta)
    }

    @Test("las claves se sustituyen por su marcador solo donde esta, y en la config solo si existen")
    func secretos() {
        #expect(substitutingSecrets("Bearer {{secret:token}}", secrets: ["token": "ntn_1"]) == "Bearer ntn_1")
        #expect(substitutingSecrets("Bearer {{secret:otro}}", secrets: ["token": "ntn_1"]) == "Bearer {{secret:otro}}")
        let config = withSecretMarkers(.object(["x": .string("1")]), present: ["token"])
        #expect(config["token"].string == "{{secret:token}}")
        #expect(config["x"].string == "1")
    }
}

@Suite("JSON del plugin por rutas")
struct JSONTests {
    @Test("leer y escribir por ruta crea objetos y listas por el camino")
    func rutas() {
        var json = PluginJSON.object([:])

        json["documents/1/properties/0/value"] = .string("{{titulo}}")
        json["folder"] = .string("/x")

        #expect(json["documents/1/properties/0/value"].string == "{{titulo}}")
        #expect(json["documents"].array?.count == 2)
        #expect(json["documents/0"] == .null)
        #expect(json.text("folder") == "/x")
        #expect(json.text("nada/que/ver") == "")
        #expect(json["documents/9/x"] == .null)
    }

    @Test("un valor Codable entra y sale del arbol")
    func codable() throws {
        struct Doc: Codable, Equatable { var name: String; var tags: [String]; var n: Int? }
        let doc = Doc(name: "a", tags: ["x", "y"], n: nil)

        let json = try PluginJSON(encoding: doc)

        #expect(json["name"].string == "a")
        #expect(json["tags/1"].string == "y")
        #expect(try json.decode(Doc.self) == doc)
    }
}
