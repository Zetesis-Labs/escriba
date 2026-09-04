import Foundation
import Testing

@testable import EscribaStore

@Suite("Titulo de una grabacion")
struct TitleTests {
    private func recording(source: String, key: String) -> StoredRecording {
        StoredRecording(
            key: key,
            sourceURL: URL(fileURLWithPath: source),
            audioURL: URL(fileURLWithPath: source),
            startedAt: .distantPast,
            importedAt: .distantPast,
            status: .done,
            lastError: nil,
            audio: .libraryCopy,
            transcript: nil)
    }

    @Test("el titulo es el nombre del fichero, no la clave tecnica")
    func nombreDelFichero() {
        let stored = recording(
            source: "/Recordings/Reunion con Aritz.m4a", key: "Notas de Voz/506619305")

        #expect(stored.title == "Reunion con Aritz")
    }

    @Test("una nota de Just Press Record se titula con su hora")
    func notaDeJPR() {
        let stored = recording(
            source: "/JPR/2026-08-31/04-59-05.m4a", key: "2026-08-31/04-59-05")

        #expect(stored.title == "04-59-05")
    }
}
