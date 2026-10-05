import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

@Suite("Vista previa del conector OKF")
struct VistaPreviaTests {
    @Test("con la plantilla de partida salen la nota y su transcripcion, como quedarian en la carpeta")
    func basica() throws {
        let ficheros = okfPreview(exportacion(), now: ahora, timeZone: madrid)

        #expect(ficheros.map(\.documentID) == ["nota", "transcripcion"])
        #expect(ficheros.map { $0.path.split(separator: "/").first.map(String.init) } == ["notas", "transcripciones"])
        let nota = try #require(ficheros.first?.contents)
        #expect(nota.hasPrefix("---\ntype: Nota de voz\n"))
        #expect(nota.contains("# Resumen\n\n"))
        #expect(nota.contains("](/transcripciones/"))
        #expect(ficheros.last?.contents.contains("**Ana:** ") == true)
    }

    @Test("sin el documento enlazado, el enlace y su encabezado desaparecen de la vista previa")
    func soloNota() throws {
        let ficheros = okfPreview(exportacion([estandar[0]]), now: ahora, timeZone: madrid)

        #expect(ficheros.count == 1)
        #expect(!(try #require(ficheros.first).contents.contains("# Transcripción")))
    }

    @Test("un documento sin cuerpo solo lleva la cabecera")
    func vacio() throws {
        let ficheros = okfPreview(exportacion([documento()]), now: ahora, timeZone: madrid)

        #expect(cuerpo(try #require(ficheros.first).contents).isEmpty)
    }
}
