import Foundation
import Testing
import EscribaCore
import EscribaNotion
import EscribaOKF

@testable import EscribaModel

@MainActor private func ajustes() -> AppSettings {
    let defaults = UserDefaults(suiteName: "escriba-okf-\(UUID().uuidString)")!
    return AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
}

@MainActor private func modelo(_ ajustes: AppSettings) -> ConnectorsModel {
    ConnectorsModel(settings: ajustes, tokens: { _ in .inMemory() })
}

@MainActor private func editor(_ ajustes: AppSettings = ajustes()) -> OKFModel {
    let conectores = modelo(ajustes)
    return conectores.okfEditor(for: conectores.add(.okf).id)
}

@MainActor
@Suite("Conector OKF")
struct ConectorOKFTests {
    @Test("añadir uno lo crea sin carpeta y con la nota y la transcripcion enlazadas")
    func nuevo() throws {
        let ajustes = ajustes()

        let conector = modelo(ajustes).add(.okf)

        #expect(conector.name == "OKF")
        #expect(conector.kind == .okf)
        let export = try #require(conector.okf)
        #expect(export.folder.isEmpty)
        #expect(export.documents.map(\.name) == ["Nota", "Transcripción"])
        #expect(export.documents[0].body.contains("{{enlace:\(export.documents[1].id)}}"))
        #expect(export.documents[1].body.contains("{{enlace:\(export.documents[0].id)}}"))
        #expect(!conector.isReady)
        #expect(ajustes.connectors == [conector])
    }

    @Test("sin carpeta la pantalla dice que falta; con carpeta y activado, publica")
    func listo() {
        let ajustes = ajustes()
        let editor = editor(ajustes)

        #expect(editor.readiness == "Elige la carpeta donde guardar las notas.")
        editor.folder = "/Users/alguien/Notas OKF"
        editor.publishes = true
        #expect(editor.readiness == nil)
        #expect(ajustes.liveConnectors.isEmpty)

        editor.save()

        #expect(ajustes.liveConnectors.map(\.okf?.folder) == ["/Users/alguien/Notas OKF"])
    }

    @Test("se pueden añadir, renombrar y quitar documentos")
    func documentos() throws {
        let editor = editor()

        let nuevo = editor.addDocument()
        #expect(editor.documents.map(\.name) == ["Nota", "Transcripción", "Documento 3"])
        editor.updateDocument(nuevo) { $0.name = "Acta" }
        #expect(editor.document(nuevo)?.name == "Acta")
        #expect(editor.document(nuevo)?.properties.first?.key == "type")

        editor.removeDocument(editor.documents[1].id)
        #expect(editor.documents.map(\.name) == ["Nota", "Acta"])
    }

    @Test("las propiedades se añaden, se editan y se quitan; type no se puede quitar")
    func propiedades() throws {
        let editor = editor()
        let nota = editor.documents[0].id

        let nueva = try #require(editor.addProperty(to: nota))
        editor.updateProperty(nueva, in: nota) {
            $0.key = "cliente"
            $0.value = "Acme"
        }
        #expect(editor.document(nota)?.properties.last == OKFProperty(id: nueva, key: "cliente", value: "Acme"))

        let tipo = try #require(editor.document(nota)?.properties.first?.id)
        editor.removeProperty(tipo, from: nota)
        #expect(editor.document(nota)?.properties.first?.key == "type")

        editor.removeProperty(nueva, from: nota)
        #expect(editor.document(nota)?.properties.contains { $0.key == "cliente" } == false)
    }

    @Test("la pantalla avisa de lo que impide exportar: sin documentos, rutas repetidas o type vacio")
    func problemas() throws {
        let editor = editor()
        editor.folder = "/bundle"
        let nota = editor.documents[0].id
        let transcripcion = editor.documents[1].id

        editor.updateDocument(transcripcion) { $0.path = editor.document(nota)?.path ?? "" }
        #expect(editor.readiness == "«Nota» y «Transcripción» escriben en la misma ruta.")

        editor.updateDocument(transcripcion) { $0.path = "otra/{{titulo}}.md" }
        editor.updateDocument(nota) { $0.properties[0].value = " " }
        #expect(editor.readiness == "«Nota» necesita un valor en type: OKF lo exige.")

        editor.removeDocument(nota)
        editor.removeDocument(transcripcion)
        #expect(editor.readiness == "Añade al menos un documento.")
    }

    @Test("los cambios quedan en borrador hasta Guardar, y Descartar vuelve a lo guardado")
    func borrador() {
        let ajustes = ajustes()
        let conectores = modelo(ajustes)
        let conector = conectores.add(.okf)
        let editor = conectores.okfEditor(for: conector.id)

        editor.updateDocument(editor.documents[0].id) { $0.body = "Solo esto" }
        #expect(editor.isDirty)
        #expect(ajustes.connector(conector.id) == conector)

        editor.discard()
        #expect(!editor.isDirty)

        editor.updateDocument(editor.documents[0].id) { $0.body = "Solo esto" }
        editor.save()
        #expect(ajustes.connector(conector.id)?.okf?.documents.first?.body == "Solo esto")
    }

    @Test("la vista previa sigue al borrador, sin esperar a Guardar")
    func vistaPrevia() {
        let editor = editor()
        #expect(editor.preview.count == 2)

        editor.removeDocument(editor.documents[1].id)
        #expect(editor.preview.count == 1)
        #expect(editor.isDirty)
    }

    @Test("cada conector tiene su propio editor, tambien si son de tipos distintos")
    func editores() {
        let conectores = modelo(ajustes())
        let notion = conectores.add(.notion)
        let okf = conectores.add(.okf)

        conectores.okfEditor(for: okf.id).folder = "/bundle"

        #expect(conectores.okfEditor(for: okf.id) === conectores.okfEditor(for: okf.id))
        #expect(conectores.editor(for: notion.id).export == nil)
        #expect(conectores.connectors.map(\.name) == ["Notion", "OKF"])
    }

    @Test("quitar un conector OKF borra su configuracion")
    func quitar() {
        let ajustes = ajustes()
        let conectores = modelo(ajustes)
        let conector = conectores.add(.okf)
        _ = conectores.okfEditor(for: conector.id)

        conectores.remove(conector.id)

        #expect(ajustes.connector(conector.id) == nil)
    }

    @Test("se guardan y vuelven con su carpeta y sus documentos")
    func persistencia() {
        let defaults = UserDefaults(suiteName: "escriba-okf-persist-\(UUID().uuidString)")!
        let antes = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
        let conector = Connector(
            name: "Equipo", kind: .okf, enabled: true,
            okf: OKFExport(folder: "/bundle", documents: OKFExport.standardDocuments()))
        antes.connectors = [conector]

        let despues = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)

        #expect(despues.connectors == [conector])
        #expect(despues.liveConnectors.map(\.name) == ["Equipo"])
    }

    @Test("un conector OKF guardado con la forma anterior conserva su carpeta y recibe los documentos de partida")
    func formaAnterior() throws {
        let viejo = """
            [{"id":"A58F36BA-0EC7-4973-B39D-FB3CFA376060","name":"OKF","kind":"okf","enabled":true,
              "okf":{"folder":"/Users/alguien/Prueba/","separateTranscript":true,
                     "template":{"blocks":[{"summary":{}}]}}},
             {"id":"7D1B5E1C-1F6B-4C7A-9F1E-2B9F1C0D4A11","name":"Notion","kind":"notion","enabled":false}]
            """

        let leidos = try JSONDecoder().decode([Connector].self, from: Data(viejo.utf8))

        #expect(leidos.map(\.kind) == [.okf, .notion])
        #expect(leidos[0].okf?.folder == "/Users/alguien/Prueba/")
        #expect(leidos[0].okf?.documents.map(\.name) == ["Nota", "Transcripción"])
    }

    @Test("borrar de un conector OKF avisa de que se borran sus ficheros, no de una papelera")
    func textoDeBorrar() {
        let okf = RowActionText.unpublish(from: .okf)
        #expect(okf.contains("Se borran sus ficheros .md"))
        #expect(okf.contains("se quedan en la biblioteca"))
        #expect(RowActionText.unpublish(from: .notion).contains("se archiva en Notion"))
    }

    @Test("quitar un conector avisa de lo que se pierde: en Notion, tambien el token")
    func avisoAlQuitar() {
        #expect(ConnectorText.removal(of: .notion).contains("token"))
        #expect(ConnectorText.removal(of: .okf).contains("siguen en la carpeta"))
    }
}
