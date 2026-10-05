import Foundation
import Testing

@testable import EscribaCore

@Suite("Filas de la plantilla del cuerpo")
struct PlantillaFilasTests {
    @Test("cada fila dice lo que produce, sin confundir el encabezado con el texto del resumen")
    func etiquetas() {
        #expect(TemplateBlock.heading("Resumen").label() == "Encabezado: Resumen")
        #expect(TemplateBlock.summary.label() == "Texto del resumen")
        #expect(TemplateBlock.field(.speakers).label() == "Dato: Hablantes")
        #expect(TemplateBlock.audio.label() == "Audio de la grabación")
        #expect(TemplateBlock.transcript(.speakers).label() == "Transcripción completa · un párrafo por hablante")
    }

    @Test("con la transcripcion en su propio fichero, su fila dice que es un enlace")
    func enlace() {
        #expect(TemplateBlock.transcript(.timestamps).label(transcriptAsLink: true)
            == "Enlace a la transcripción completa · con marca de tiempo")
        #expect(TemplateBlock.summary.label(transcriptAsLink: true) == "Texto del resumen")
    }

    @Test("un encabezado se renombra sin dejar de ser encabezado, y un texto sigue siendo texto")
    func renombrar() {
        let plantilla = BodyTemplate([.heading("Resumen"), .text("hola"), .summary])

        #expect(plantilla.settingText("Ideas", at: 0).blocks == [.heading("Ideas"), .text("hola"), .summary])
        #expect(plantilla.settingText("adios", at: 1).blocks == [.heading("Resumen"), .text("adios"), .summary])
        #expect(plantilla.settingText("x", at: 2) == plantilla)
    }
}
