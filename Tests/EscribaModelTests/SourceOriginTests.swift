import Foundation
import Testing

@testable import EscribaModel

@Suite("De que carpeta viene cada grabacion")
struct SourceOriginTests {
    private let jpr = WatchedFolder(path: "/JPR", style: .justPressRecord)
    private let memos = WatchedFolder(path: "/Recordings", style: .voiceMemos)
    private let llamadas = WatchedFolder(path: "/audios/llamadas", style: .any)
    private let audios = WatchedFolder(path: "/audios", style: .any)

    @Test("una grabacion se atribuye a la carpeta que la contiene")
    func porCarpeta() {
        let folders = [jpr, memos]

        #expect(folder(for: "/Recordings/nota.m4a", among: folders) == memos)
        #expect(folder(for: "/JPR/2026-08-31/04-59-05.m4a", among: folders) == jpr)
    }

    @Test("con carpetas anidadas gana la mas concreta")
    func anidadas() {
        let folders = [audios, llamadas]

        #expect(folder(for: "/audios/llamadas/x.m4a", among: folders) == llamadas)
        #expect(folder(for: "/audios/otra/x.m4a", among: folders) == audios)
    }

    @Test("una carpeta que solo comparte prefijo de texto no cuela")
    func prefijoEnganoso() {
        #expect(folder(for: "/audios-viejos/x.m4a", among: [audios]) == nil)
    }

    @Test("lo que no cae en ninguna carpeta vigilada no se atribuye")
    func sinCarpeta() {
        #expect(folder(for: "/otro/sitio/x.m4a", among: [jpr, memos]) == nil)
    }

    @Test("cada estilo se presenta con su nombre")
    func nombres() {
        #expect(jpr.displayName == "Just Press Record")
        #expect(memos.displayName == "Notas de Voz")
        #expect(llamadas.displayName == "llamadas")
    }
}
