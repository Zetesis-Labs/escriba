import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

private let entorno = ProcessInfo.processInfo.environment
private let tokenEnVivo = entorno["ESCRIBA_NOTION_TOKEN"]

@Suite("Contra la API real de Notion (solo con ESCRIBA_NOTION_TOKEN)", .enabled(if: tokenEnVivo != nil))
struct EnVivoTests {
    @Test("listar bases, publicar, republicar sin duplicar y dejar el enlace")
    func idaYVuelta() async throws {
        let client = makeNotionClient(token: try #require(tokenEnVivo))

        let bases = try await client.dataSources()
        let deseada = entorno["ESCRIBA_NOTION_DATA_SOURCE"]
        let base = try #require(bases.first { deseada == nil || deseada == $0.id })
        print("BASE:", base.label, base.properties.map { "\($0.name):\($0.type)" })

        let mapeo = suggestedMapping(for: base)
        print("MAPEO:", mapeo.assigned.map { "\($0.key.rawValue)→\($0.value)" }.sorted())
        let audio = entorno["ESCRIBA_NOTION_AUDIO"].map { URL(fileURLWithPath: $0) }
        let ficha: [TemplateBlock] = [
            .heading("Ficha"), .field(.date), .field(.speakers), .field(.duration),
        ] + (audio == nil ? [] : [.audio])
        let export = NotionExport(
            source: base, mapping: mapeo, template: BodyTemplate(ficha + [.transcript(.timestamps)]))
        #expect(export.isUsable)

        let clave = "escriba-verificacion-\(Int(Date().timeIntervalSince1970))"
        let grabacion = Recording(
            url: audio ?? URL(fileURLWithPath: "/Notas/\(clave).m4a"), startedAt: .now, key: clave)
        let esperados = ficha.count + 120
        let larga = Transcript(segments: (0..<120).map { i in
            TranscriptSegment(
                start: Double(i * 7), end: Double(i * 7 + 6), speaker: i % 2 == 0 ? "Rubén" : "Aritz",
                text: "Turno \(i) de la verificación en vivo de Escriba contra Notion.")
        })

        let primera = try await publish(grabacion, larga, as: export, using: client)
        print("CREADA:", primera.id, primera.url?.absoluteString ?? "sin url")
        #expect(primera.url != nil)
        #expect(try await client.childBlocks(primera.id).count == esperados)

        let corregida = larga.renaming("Aritz", to: "Aritz (corregido)")
        var regenerada = export
        regenerada.template = BodyTemplate(ficha + [.transcript(.speakers)])
        let segunda = try await publish(
            grabacion, corregida, as: regenerada, using: client, known: primera)
        #expect(segunda.id == primera.id)
        #expect(try await client.childBlocks(segunda.id).count == esperados)
        print("REESCRITA:", segunda.id)
    }
}
