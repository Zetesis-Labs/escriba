import Foundation
import Synchronization
import Testing
import EscribaCore
import EscribaEngine

@testable import EscribaOKF

private func carpetaTemporal() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "escriba-okf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func leer(_ raiz: URL, _ ruta: String) -> String? {
    try? String(contentsOf: raiz.appending(path: ruta), encoding: .utf8)
}

private final class Diario: Sendable {
    let publicadas = Mutex<[(String, String)]>([])
    let fallos = Mutex<[String]>([])
    let conocida = Mutex<String?>(nil)

    var journal: OKFJournal {
        OKFJournal(
            known: { _ in self.conocida.withLock { $0 } },
            published: { key, path, _ in self.publicadas.withLock { $0.append((key, path)) } },
            failed: { key, _ in self.fallos.withLock { $0.append(key) } })
    }
}

@Suite("Destino OKF sobre una carpeta de verdad")
struct OKFSinkTests {
    @Test("escribe el bundle en la carpeta, anota la ruta y devuelve el fichero de la nota")
    func escribe() async throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let diario = Diario()
        let sink = okfSink(
            export: OKFExport(folder: raiz.path), folder: fileFolder(raiz), journal: diario.journal,
            producer: productor, timeZone: madrid, now: { ahora })

        let salida = try await sink(nota)

        #expect(salida.standardizedFileURL == raiz.appending(path: "notas/2025-09-16-backups-de-cortes.md").standardizedFileURL)
        #expect(leer(raiz, "notas/2025-09-16-backups-de-cortes.md")?.hasPrefix("---\ntype: Nota de voz\n") == true)
        #expect(leer(raiz, "transcripciones/2025-09-16-backups-de-cortes.md") != nil)
        #expect(leer(raiz, "log.md")?.contains("**Alta**") == true)
        #expect(leer(raiz, "index.md") != nil)
        #expect(diario.publicadas.withLock { $0.map(\.0) } == ["llamada"])
        #expect(diario.publicadas.withLock { $0.map(\.1) } == ["notas/2025-09-16-backups-de-cortes.md"])
    }

    @Test("regenerar con la ruta anotada sustituye la nota en vez de duplicarla")
    func regenera() async throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let diario = Diario()
        let sink = okfSink(
            export: OKFExport(folder: raiz.path), folder: fileFolder(raiz), journal: diario.journal,
            producer: productor, timeZone: madrid, now: { ahora })
        _ = try await sink(nota)
        diario.conocida.withLock { $0 = "notas/2025-09-16-backups-de-cortes.md" }

        let corregida = Note(
            recording: grabacion, transcript: diarizada,
            digest: Digest(title: "Restore de cortes", summary: "Otra.", tags: []))
        _ = try await sink(corregida)

        let notas = try FileManager.default.contentsOfDirectory(atPath: raiz.appending(path: "notas").path).sorted()
        #expect(notas == ["2025-09-16-restore-de-cortes.md", "index.md"])
    }

    @Test("si no puede escribir, lo anota en el diario y lanza el error")
    func falla() async throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let fichero = raiz.appending(path: "no-es-carpeta")
        try "x".write(to: fichero, atomically: true, encoding: .utf8)
        let diario = Diario()
        let sink = okfSink(
            export: OKFExport(folder: fichero.path), folder: fileFolder(fichero), journal: diario.journal,
            producer: productor, timeZone: madrid, now: { ahora })

        await #expect(throws: (any Error).self) { _ = try await sink(nota) }
        #expect(diario.fallos.withLock { $0 } == ["llamada"])
        #expect(diario.publicadas.withLock { $0.isEmpty })
    }

    @Test("despublicar borra los ficheros de la nota y anota la baja")
    func despublica() async throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let carpeta = fileFolder(raiz)
        _ = try await okfSink(
            export: OKFExport(folder: raiz.path), folder: carpeta, producer: productor, timeZone: madrid,
            now: { ahora })(nota)

        try okfUnpublish("notas/2025-09-16-backups-de-cortes.md", from: carpeta, timeZone: madrid, now: { ahora })

        #expect(leer(raiz, "notas/2025-09-16-backups-de-cortes.md") == nil)
        #expect(leer(raiz, "transcripciones/2025-09-16-backups-de-cortes.md") == nil)
        #expect(leer(raiz, "log.md")?.contains("**Baja**") == true)
    }
}
