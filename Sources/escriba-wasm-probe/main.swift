import Foundation
import EscribaCore
import EscribaEngine
import EscribaNotion
import EscribaOKF

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

let resumen = Digest(
    title: "El nucleo viaja",
    summary: "Ruben y Aritz comprueban que el motor corre en WebAssembly.",
    tags: ["wasi", "nucleo"])
let trozos = digestChunks(of: transcript.rendered, maxCharacters: 30)
print("trozos para resumir:", trozos.count, "| etiquetas:", normalizedTags(["#WASI", "wasi", "Nucleo"]).joined(separator: ", "))

let base = NotionDataSource(
    id: "ds-wasi", databaseTitle: "Notas", title: "Notas",
    properties: [
        NotionProperty(name: "Nombre", type: "title"),
        NotionProperty(name: "Hablantes", type: "multi_select"),
    ])
let export = NotionExport(
    source: base, columns: suggestedColumns(for: base),
    body: "**Hablantes:** {{hablantes}}\n{{resumen}}\n{{etiquetas}}\n{{transcripcion-tiempos}}")
let page = notionPage(
    for: Note(recording: recordings[0], transcript: transcript, digest: resumen), as: export,
    timeZone: TimeZone(identifier: "UTC")!)
let body = createPageBody(page, in: export.source)
print("bloques para Notion:", body["children"]?.count ?? 0, "| titulo:", body["properties"]?["Nombre"]?["title"]?[0]?["text"]?["content"]?.text ?? "?")

let bundle = okfPublication(
    Note(recording: recordings[0], transcript: transcript, digest: resumen),
    as: OKFExport(folder: "/bundle"), in: bundleState(from: [:]),
    producer: "escriba/wasi", now: Date(timeIntervalSince1970: 1_758_013_200),
    timeZone: TimeZone(identifier: "UTC")!)
print("ficheros del bundle OKF:", bundle.changes.count, "| nota:", bundle.notePath)
