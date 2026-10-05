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

@MainActor
@Suite("Conector OKF")
struct ConectorOKFTests {
    @Test("añadir uno lo crea sin carpeta, con el resumen y la transcripcion aparte por defecto")
    func nuevo() {
        let ajustes = ajustes()

        let conector = modelo(ajustes).add(.okf)

        #expect(conector.name == "OKF")
        #expect(conector.kind == .okf)
        #expect(conector.okf == OKFExport(folder: ""))
        #expect(conector.okf?.separateTranscript == true)
        #expect(conector.okf?.template.blocks.contains(.summary) == true)
        #expect(!conector.isReady)
        #expect(ajustes.connectors == [conector])
    }

    @Test("sin carpeta la pantalla dice que falta; con carpeta y activado, publica")
    func listo() {
        let ajustes = ajustes()
        let conectores = modelo(ajustes)
        let editor = conectores.okfEditor(for: conectores.add(.okf).id)

        #expect(editor.readiness == "Elige la carpeta donde guardar las notas.")
        editor.folder = "/Users/alguien/Notas OKF"
        editor.publishes = true
        #expect(editor.readiness == nil)
        #expect(ajustes.liveConnectors.isEmpty)

        editor.save()

        #expect(ajustes.liveConnectors.map(\.okf?.folder) == ["/Users/alguien/Notas OKF"])
    }

    @Test("los cambios quedan en borrador hasta Guardar, y Descartar vuelve a lo guardado")
    func borrador() {
        let ajustes = ajustes()
        let conectores = modelo(ajustes)
        let conector = conectores.add(.okf)
        let editor = conectores.okfEditor(for: conector.id)

        editor.name = "Bundle del equipo"
        editor.separateTranscript = false
        editor.template = BodyTemplate([.summary])
        #expect(editor.isDirty)
        #expect(ajustes.connector(conector.id) == conector)

        editor.discard()
        #expect(!editor.isDirty)
        #expect(editor.separateTranscript)

        editor.separateTranscript = false
        editor.template = BodyTemplate([.summary])
        editor.save()
        #expect(ajustes.connector(conector.id)?.okf?.separateTranscript == false)
        #expect(ajustes.connector(conector.id)?.okf?.template == BodyTemplate([.summary]))
        #expect(!editor.isDirty)
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

    @Test("se guardan y vuelven con su carpeta, su plantilla y el interruptor")
    func persistencia() {
        let defaults = UserDefaults(suiteName: "escriba-okf-persist-\(UUID().uuidString)")!
        let antes = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
        let conector = Connector(
            name: "Equipo", kind: .okf, enabled: true,
            okf: OKFExport(folder: "/bundle", template: BodyTemplate([.summary]), separateTranscript: false))
        antes.connectors = [conector]

        let despues = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)

        #expect(despues.connectors == [conector])
        #expect(despues.liveConnectors.map(\.name) == ["Equipo"])
    }

    @Test("unos conectores guardados antes de existir OKF se leen igual")
    func compatibilidad() throws {
        let viejo = """
            [{"id":"7D1B5E1C-1F6B-4C7A-9F1E-2B9F1C0D4A11","name":"Notion","kind":"notion","enabled":false}]
            """

        let leidos = try JSONDecoder().decode([Connector].self, from: Data(viejo.utf8))

        #expect(leidos.map(\.kind) == [.notion])
        #expect(leidos.first?.okf == nil)
    }

    @Test("borrar de un conector OKF avisa de que se borran sus ficheros, no de una papelera")
    func textoDeBorrar() {
        let okf = RowActionText.unpublish(from: .okf)
        #expect(okf.contains("Se borran sus ficheros .md"))
        #expect(okf.contains("se quedan en la biblioteca"))
        #expect(RowActionText.unpublish(from: .notion).contains("se archiva en Notion"))
    }

    @Test("la vista previa sigue al borrador, sin esperar a Guardar")
    func vistaPrevia() {
        let conectores = modelo(ajustes())
        let editor = conectores.okfEditor(for: conectores.add(.okf).id)
        #expect(editor.preview.count == 2)

        editor.separateTranscript = false
        #expect(editor.preview.count == 1)

        editor.template = BodyTemplate([.summary])
        #expect(editor.preview.first?.contents.contains("Transcripción") == false)
        #expect(editor.isDirty)
    }
}
