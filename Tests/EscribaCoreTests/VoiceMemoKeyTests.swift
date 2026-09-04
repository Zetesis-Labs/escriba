import Foundation
import Testing

@testable import EscribaCore

@Suite("Identidad de una nota de voz")
struct VoiceMemoKeyTests {
    private let root = URL(fileURLWithPath: "/Recordings")

    private func entry(
        _ path: String, id: UInt64? = nil, modified: Date = .distantPast
    ) -> DirectoryEntry {
        DirectoryEntry(
            url: URL(fileURLWithPath: path), fileIdentifier: id, modifiedAt: modified)
    }

    @Test("la clave es el identificador del fichero, no el nombre")
    func claveEsElIdentificador() {
        let entries = [entry("/Recordings/Reunion con Aritz.m4a", id: 4321)]

        #expect(voiceMemoRecordings(entries, root: root).map(\.key) == ["4321"])
    }

    @Test("renombrar la nota no cambia su clave")
    func renombrarNoCambiaLaClave() {
        let antes = [entry("/Recordings/Nueva grabacion 3.m4a", id: 4321)]
        let despues = [entry("/Recordings/Reunion con Aritz.m4a", id: 4321)]

        #expect(
            voiceMemoRecordings(antes, root: root).map(\.key)
                == voiceMemoRecordings(despues, root: root).map(\.key))
    }

    @Test("dos notas distintas con el mismo nombre no se pisan")
    func nombresDuplicados() {
        let entries = [
            entry("/Recordings/Nueva grabacion.m4a", id: 1),
            entry("/Recordings/Nueva grabacion.m4a", id: 2),
        ]

        #expect(voiceMemoRecordings(entries, root: root).map(\.key) == ["1", "2"])
    }

    @Test("sin identificador de fichero la clave cae a la ruta relativa")
    func sinIdentificador() {
        let entries = [entry("/Recordings/20260903 175635.m4a")]

        #expect(voiceMemoRecordings(entries, root: root).map(\.key) == ["20260903 175635"])
    }

    @Test("los fragmentos de edicion en subcarpetas se ignoran")
    func fragmentosDeEdicion() {
        let entries = [
            entry("/Recordings/buena.m4a", id: 1),
            entry("/Recordings/edicion.composition/fragmento.m4a", id: 2),
            entry("/Recordings/Trash/borrada.m4a", id: 3),
        ]

        #expect(voiceMemoRecordings(entries, root: root).map(\.key) == ["1"])
    }

    @Test("lo que no es audio se ignora")
    func noAudio() {
        let entries = [entry("/Recordings/nota.m4a", id: 1), entry("/Recordings/x.plist", id: 2)]

        #expect(voiceMemoRecordings(entries, root: root).map(\.key) == ["1"])
    }

    @Test("un fichero de fuera de la carpeta no pertenece a la fuente")
    func fueraDelRoot() {
        #expect(voiceMemoRecordings([entry("/otro/x.m4a", id: 1)], root: root).isEmpty)
    }

    @Test("la fecha de la grabacion es la de modificacion del fichero")
    func fecha() {
        let cuando = Date(timeIntervalSince1970: 1_788_451_234)
        let entries = [entry("/Recordings/x.m4a", id: 1, modified: cuando)]

        #expect(voiceMemoRecordings(entries, root: root).map(\.startedAt) == [cuando])
    }

    @Test("las grabaciones salen ordenadas de mas antigua a mas nueva")
    func orden() {
        let entries = [
            entry("/Recordings/b.m4a", id: 2, modified: Date(timeIntervalSince1970: 200)),
            entry("/Recordings/a.m4a", id: 1, modified: Date(timeIntervalSince1970: 100)),
        ]

        #expect(voiceMemoRecordings(entries, root: root).map(\.key) == ["1", "2"])
    }
}
