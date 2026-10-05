import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

private let entorno = ProcessInfo.processInfo.environment
private let tokenEnVivo = entorno["ESCRIBA_NOTION_TOKEN"]

extension Optional {
    fileprivate func asyncFlatMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

@Suite("Contra la API real de Notion (solo con ESCRIBA_NOTION_TOKEN)", .enabled(if: tokenEnVivo != nil))
struct EnVivoTests {
    @Test("listar bases, publicar, republicar sin duplicar y dejar el enlace")
    func idaYVuelta() async throws {
        let client = makeNotionClient(token: try #require(tokenEnVivo))

        let bases = try await client.dataSources()
        let deseada = entorno["ESCRIBA_NOTION_DATA_SOURCE"]
        let base = try #require(bases.first { deseada == nil || deseada == $0.id })
        print("BASE:", base.label, base.properties.map { "\($0.name):\($0.type)" })

        let columnas = suggestedColumns(for: base)
        print("COLUMNAS:", columnas.map { "\($0.key)=\($0.value)" }.sorted())
        let audio = entorno["ESCRIBA_NOTION_AUDIO"].map { URL(fileURLWithPath: $0) }
        let ficha = [
            "# Ficha", "**Fecha:** {{fecha}}", "**Hablantes:** {{hablantes}}", "**Duración:** {{duracion}}",
            "**Etiquetas:** {{etiquetas}}", "{{resumen}}",
        ] + (audio == nil ? [] : ["{{audio}}"])
        let export = NotionExport(
            source: base, columns: columnas, body: (ficha + ["{{transcripcion-tiempos}}"]).joined(separator: "\n"))
        #expect(export.isUsable)

        let clave = "escriba-verificacion-\(Int(Date().timeIntervalSince1970))"
        let grabacion = Recording(
            url: audio ?? URL(fileURLWithPath: "/Notas/\(clave).m4a"), startedAt: .now, key: clave)
        let esperados = ficha.count + 120
        var segmentos: [TranscriptSegment] = []
        for turno in 0..<120 {
            let inicio = Double(turno * 7)
            let hablante = turno % 2 == 0 ? "Rubén" : "Aritz"
            segmentos.append(
                TranscriptSegment(
                    start: inicio, end: inicio + 6, speaker: hablante,
                    text: "Turno \(turno) de la verificación en vivo de Escriba contra Notion."))
        }
        let larga = Transcript(segments: segmentos)
        let resumen = Digest(
            title: "Verificación en vivo de Escriba",
            summary: "Rubén y Aritz se turnan para comprobar que la publicación en Notion funciona.",
            tags: ["verificación", "notion"])
        let nota = Note(recording: grabacion, transcript: larga, digest: resumen)

        let primera = try await publish(nota, as: export, using: client)
        print("CREADA:", primera.id, primera.url?.absoluteString ?? "sin url")
        #expect(primera.url != nil)
        #expect(try await client.childBlocks(primera.id).count == esperados)

        let corregida = larga.renaming("Aritz", to: "Aritz (corregido)")
        var regenerada = export
        regenerada.body = (ficha + ["{{transcripcion}}"]).joined(separator: "\n")
        let segunda = try await publish(
            Note(recording: grabacion, transcript: corregida, digest: resumen), as: regenerada,
            using: client, known: primera)
        #expect(segunda.id == primera.id)
        #expect(try await client.childBlocks(segunda.id).count == esperados)
        print("REESCRITA:", segunda.id)

        try await unpublish(pageId: segunda.id, using: client)
        let buscada = try await findByKeyBody(clave, column: export.keyColumn).asyncFlatMap {
            try await client.findPage(base.id, $0)
        }
        #expect(buscada == nil)
        print("ARCHIVADA:", segunda.id)
    }
}
