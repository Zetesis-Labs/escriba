import Foundation
import Testing

@testable import EscribaCore

@Suite("Plantilla de texto con datos")
struct PlantillaTextoTests {
    @Test("el texto y los datos se separan, y se vuelven a unir igual")
    func idaYVuelta() {
        let fuente = "# Resumen\n\n{{resumen}}\n\nVer {{enlace:doc-2}} · {{transcripcion-tiempos}}"

        let piezas = templatePieces(fuente)

        #expect(piezas == [
            .text("# Resumen\n\n"), .token(.summary), .text("\n\nVer "), .token(.link("doc-2")),
            .text(" · "), .token(.transcript(.timestamps)),
        ])
        #expect(templateSource(piezas) == fuente)
    }

    @Test("lo que no es un dato conocido se queda como texto, llaves incluidas")
    func desconocido() {
        #expect(templatePieces("{{no-existe}} y {{ titulo }} y {titulo}") == [.text("{{no-existe}} y {{ titulo }} y {titulo}")])
        #expect(templatePieces("{{titulo") == [.text("{{titulo")])
        #expect(templatePieces("") == [])
    }

    @Test("cada dato tiene su marca estable para guardarlo")
    func marcas() {
        for token in TemplateToken.catalog {
            #expect(TemplateToken(marker: token.marker) == token)
        }
        #expect(TemplateToken(marker: "enlace:abc") == .link("abc"))
        #expect(TemplateToken(marker: "enlace:") == nil)
    }

    @Test("el menu de / filtra por lo escrito, sin tildes ni mayusculas")
    func filtro() {
        let titulos = tokenSuggestions(matching: "tit", in: .body).map(\.token)
        #expect(titulos == [.title])

        let transcripciones = tokenSuggestions(matching: "TRANSCRIPCION", in: .body).map(\.token)
        #expect(transcripciones == [.transcript(.speakers), .transcript(.timestamps), .transcript(.plain)])

        #expect(tokenSuggestions(matching: "", in: .body).count == TemplateToken.catalog.count)
        #expect(tokenSuggestions(matching: "zzz", in: .body).isEmpty)
    }

    @Test("en la ruta solo se ofrecen datos que sirven para nombrar un fichero")
    func ruta() {
        #expect(tokenSuggestions(matching: "", in: .path).map(\.token) == [.day, .title, .key])
    }

    @Test("los enlaces ofrecen los otros documentos por su nombre, nunca el propio")
    func enlaces() {
        let otros = [LinkTarget(id: "a", name: "Nota"), LinkTarget(id: "b", name: "Transcripción")]

        let sugerencias = tokenSuggestions(matching: "enl", in: .body, links: otros, excluding: "a")

        #expect(sugerencias.map(\.token) == [.link("b")])
        #expect(sugerencias.first?.label == "Enlace a «Transcripción»")
        #expect(tokenSuggestions(matching: "transcripcion", in: .body, links: otros).map(\.token).contains(.link("b")))
    }

    @Test("la pastilla de cada dato dice que es")
    func etiquetas() {
        #expect(TemplateToken.title.label() == "Título")
        #expect(TemplateToken.transcript(.timestamps).label() == "Transcripción con tiempos")
        #expect(TemplateToken.link("b").label(names: ["b": "Transcripción"]) == "Enlace a «Transcripción»")
        #expect(TemplateToken.link("borrado").label(names: [:]) == "Enlace a un documento que ya no existe")
    }
}
