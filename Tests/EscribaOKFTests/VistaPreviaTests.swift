import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

@Suite("Vista previa del conector OKF")
struct VistaPreviaTests {
    @Test("con la plantilla basica salen la nota y su transcripcion, como quedarian en la carpeta")
    func basica() throws {
        let ficheros = okfPreview(OKFExport(folder: "/bundle"), now: ahora, timeZone: madrid)

        #expect(ficheros.map(\.path).map { $0.split(separator: "/").first.map(String.init) } == ["notas", "transcripciones"])
        let nota = try #require(ficheros.first?.contents)
        #expect(nota.hasPrefix("---\ntype: Nota de voz\n"))
        #expect(nota.contains("# Resumen\n\n"))
        #expect(nota.contains("[Transcripción completa](/transcripciones/"))
        #expect(ficheros.last?.contents.contains("**Ana:** ") == true)
    }

    @Test("con todo junto sale un solo fichero con la transcripcion dentro")
    func junta() throws {
        let ficheros = okfPreview(OKFExport(folder: "/bundle", separateTranscript: false), now: ahora, timeZone: madrid)

        #expect(ficheros.count == 1)
        #expect(try #require(ficheros.first).contents.contains("# Transcripción\n\n**Ana:** "))
    }

    @Test("con la plantilla vacia la nota solo lleva la cabecera")
    func vacia() throws {
        let ficheros = okfPreview(OKFExport(folder: "/bundle", template: BodyTemplate([])), now: ahora, timeZone: madrid)

        #expect(ficheros.count == 1)
        #expect(cuerpo(try #require(ficheros.first).contents).isEmpty)
    }
}
