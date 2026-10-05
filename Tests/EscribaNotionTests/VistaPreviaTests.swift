import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

@Suite("Vista previa del conector de Notion")
struct VistaPreviaNotionTests {
    @Test("enseña cada columna con su valor y el cuerpo como quedaria en la pagina")
    func vistaPrevia() {
        let preview = notionPreview(
            exportDe(cuerpo: "# Resumen\n{{resumen}}\n- {{hablantes}}\n{{audio}}\n{{transcripcion}}"),
            now: inicioLlamada, timeZone: zonaMadrid)

        #expect(preview.properties.first == NotionPreview.Property(name: "Nombre", value: "Lanzamiento del jueves"))
        #expect(preview.properties.contains(NotionPreview.Property(name: "Hablantes", value: "Ana, Luis")))
        #expect(preview.properties.contains(NotionPreview.Property(name: "Temas", value: "lanzamiento, migración")))
        #expect(preview.text.hasPrefix("# Resumen\n\nAna y Luis repasan"))
        #expect(preview.text.contains("• Ana, Luis\n\n▶︎ Audio\n\nAna: ¿Cómo vamos"))
    }

    @Test("una columna que se vacia se ve como raya, no desaparece")
    func vacia() {
        let preview = notionPreview(
            exportDe(columnas: ["Nombre": "{{titulo}}", "Estado": "{{enlace:x}}"]), now: inicioLlamada,
            timeZone: zonaMadrid)

        #expect(preview.properties == [
            NotionPreview.Property(name: "Nombre", value: "Lanzamiento del jueves"),
            NotionPreview.Property(name: "Estado", value: "—"),
        ])
    }
}
