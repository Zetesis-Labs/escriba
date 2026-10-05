import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

@Suite("Nombre de fichero de la nota")
struct NombreTests {
    @Test("fecha de la grabacion en la zona del usuario y el titulo en minusculas, sin tildes ni signos")
    func nombre() {
        let casiMedianoche = Date(timeIntervalSince1970: 1_758_065_400)
        #expect(okfFileName(title: "¿Qué tal, Iñaki? (parte 2)", startedAt: casiMedianoche, timeZone: madrid)
            == "2025-09-17-que-tal-inaki-parte-2.md")
        #expect(okfFileName(title: "¿Qué tal?", startedAt: casiMedianoche, timeZone: TimeZone(identifier: "UTC")!)
            == "2025-09-16-que-tal.md")
    }

    @Test("un titulo sin letras ni numeros da un nombre generico")
    func vacio() {
        #expect(slug("¿?¡!…") == "nota")
        #expect(slug("") == "nota")
    }

    @Test("un titulo muy largo se corta por una palabra entera")
    func largo() {
        let corto = slug(String(repeating: "transcripcion ", count: 20))
        #expect(corto.count <= okfSlugLimit)
        #expect(!corto.hasSuffix("-"))
        #expect(corto.split(separator: "-").allSatisfy { $0 == "transcripcion" })
    }

    @Test("si otra grabacion ya ocupa el nombre, la nueva lleva sufijo")
    func colision() {
        let ocupado = okfNoteFile(key: "otra", title: "Backups de cortes", recorded: grabacion.startedAt)
        let publicacion = publicar(en: ocupado)

        #expect(publicacion.notePath == "notas/2025-09-16-backups-de-cortes-2.md")
    }

    @Test("un fichero que el usuario dejo en la carpeta con ese nombre tambien cuenta como ocupado")
    func ocupadoPorElUsuario() {
        let suyo = ["notas/2025-09-16-backups-de-cortes.md": "---\ntype: Idea\n---\n\nMio."]

        #expect(publicar(en: suyo).notePath == "notas/2025-09-16-backups-de-cortes-2.md")
    }

    @Test("la misma grabacion conserva su nombre al regenerarse")
    func mismaGrabacion() {
        let primera = publicar()
        let ficheros = aplicar(primera.changes, a: [:])

        #expect(publicar(en: ficheros, conocida: primera.notePath).notePath == primera.notePath)
        #expect(publicar(en: ficheros).notePath == primera.notePath)
    }
}

func okfNoteFile(key: String, title: String, recorded: Date) -> [String: String] {
    let otra = Note(
        recording: Recording(url: URL(fileURLWithPath: "/Notas/\(key).m4a"), startedAt: recorded, key: key),
        transcript: diarizada,
        digest: Digest(title: title, summary: "Otra cosa.", tags: []))
    return aplicar(publicar(otra).changes, a: [:])
}
