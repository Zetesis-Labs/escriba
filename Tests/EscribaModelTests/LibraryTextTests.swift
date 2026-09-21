import Testing
import EscribaStore

@testable import EscribaModel

@Suite("Textos de la biblioteca")
struct LibraryTextTests {
    @Test("el resumen cuenta el total y, solo si hay, lo que falta por transcribir")
    func resumen() {
        #expect(librarySummary(of: []) == "0 en la biblioteca")
        #expect(librarySummary(of: [.done, .done]) == "2 en la biblioteca")
        #expect(librarySummary(of: [.done, .pending, .failed]) == "3 en la biblioteca, 2 sin transcribir")
    }

    @Test("borrar de un conector deja claro que la pagina se archiva y la biblioteca no se toca")
    func borrarDelConector() {
        let texto = RowActionText.unpublish(from: "Notion")
        #expect(texto.contains("se archiva en Notion"))
        #expect(texto.contains("se quedan en la biblioteca"))
    }

    @Test("quitar el audio avisa distinto segun exista o no el original")
    func quitarAudio() {
        #expect(RowActionText.removeAudio(originalExists: true).contains("el original en su carpeta se conserva"))
        #expect(RowActionText.removeAudio(originalExists: false).contains("se pierde del todo"))
    }
}
