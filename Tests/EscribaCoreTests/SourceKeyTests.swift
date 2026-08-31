import Foundation
import Testing

@testable import EscribaCore

@Suite("Clave de una grabacion en una carpeta cualquiera")
struct SourceKeyTests {
    private let root = URL(fileURLWithPath: "/audios")

    @Test("la clave es la ruta relativa sin extension")
    func rutaRelativa() {
        let url = URL(fileURLWithPath: "/audios/llamadas/2026/manana.m4a")

        #expect(recordingKey(for: url, root: root) == "llamadas/2026/manana")
    }

    @Test("un fichero suelto en la raiz tambien vale")
    func enLaRaiz() {
        #expect(recordingKey(for: URL(fileURLWithPath: "/audios/nota.wav"), root: root) == "nota")
    }

    @Test("acepta los formatos de audio y video habituales")
    func formatos() {
        for ext in ["m4a", "MP3", "wav", "mp4", "mov", "opus", "flac"] {
            let url = URL(fileURLWithPath: "/audios/x.\(ext)")
            #expect(recordingKey(for: url, root: root) == "x", "fallo con \(ext)")
        }
    }

    @Test("lo que no es audio se ignora")
    func noAudio() {
        #expect(recordingKey(for: URL(fileURLWithPath: "/audios/notas.txt"), root: root) == nil)
        #expect(recordingKey(for: URL(fileURLWithPath: "/audios/foto.jpg"), root: root) == nil)
    }

    @Test("un fichero de fuera de la carpeta no pertenece a la fuente")
    func fueraDelRoot() {
        #expect(recordingKey(for: URL(fileURLWithPath: "/otro/x.m4a"), root: root) == nil)
    }

    @Test("una carpeta que solo comparte prefijo no cuela")
    func prefijoEnganoso() {
        #expect(recordingKey(for: URL(fileURLWithPath: "/audios-viejos/x.m4a"), root: root) == nil)
    }

    @Test("da igual que la carpeta venga con barra final")
    func barraFinal() {
        let conBarra = URL(fileURLWithPath: "/audios/")

        #expect(recordingKey(for: URL(fileURLWithPath: "/audios/x.m4a"), root: conBarra) == "x")
    }
}
