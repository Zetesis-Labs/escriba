import Foundation
import EscribaCore
import EscribaEngine
import EscribaNotion

let transcript = Transcript(segments: [
    TranscriptSegment(start: 0, end: 2, speaker: "Ruben", text: "Hola desde WASI."),
    TranscriptSegment(start: 2, end: 5, speaker: "Aritz", text: "Funciona el nucleo."),
])
print(transcript.rendered)

let recordings = (1...3).map {
    Recording(
        url: URL(fileURLWithPath: "/notas/\($0).m4a"),
        startedAt: Date(timeIntervalSince1970: TimeInterval(1_758_013_200 + $0)), key: "nota-\($0)")
}
let pending = selectPending(recordings, done: ["nota-2"])
print("pendientes:", pending.map(\.key).joined(separator: ", "))
print("siguiente pasada:", nextWakeInterval(
    after: PassOutcome(processed: 0, deferred: 1), retryInterval: 10, reconcileInterval: 300), "s")

let base = NotionDataSource(
    id: "ds-wasi", databaseTitle: "Notas", title: "Notas",
    properties: [
        NotionProperty(name: "Nombre", type: "title"),
        NotionProperty(name: "Hablantes", type: "multi_select"),
    ])
let export = NotionExport(
    source: base, mapping: suggestedMapping(for: base),
    template: BodyTemplate([.field(.speakers), .transcript(.timestamps)]))
let page = notionPage(for: recordings[0], transcript: transcript)
let body = createPageBody(
    page.replacing(blocks: render(export.template, for: page, transcript: transcript, audio: nil)),
    in: export.source, mapping: export.mapping, timeZone: TimeZone(identifier: "UTC")!)
print("bloques para Notion:", body["children"]?.count ?? 0, "| titulo:", body["properties"]?["Nombre"]?["title"]?[0]?["text"]?["content"]?.text ?? "?")
