import Foundation
import EscribaCore
import EscribaNotion

let zonaMadrid = TimeZone(identifier: "Europe/Madrid")!
let inicioLlamada = Date(timeIntervalSince1970: 1_758_013_200)

let charla = Transcript(segments: [
    TranscriptSegment(start: 0, end: 12, speaker: "Ruben", text: "Hola."),
    TranscriptSegment(start: 12, end: 187, speaker: "Aritz", text: "Dime."),
])

let resumenDeCharla = Digest(
    title: "Backups de cortes", summary: "Se revisa el restore.\nY se habla de MinIO.",
    tags: ["backups", "talos linux"])

func notaDe(
    _ transcript: Transcript = charla, digest: Digest? = nil, key: String = "llamada",
    url: URL = URL(fileURLWithPath: "/Notas/llamada.m4a")
) -> Note {
    Note(recording: Recording(url: url, startedAt: inicioLlamada, key: key), transcript: transcript, digest: digest)
}

func valoresDe(_ nota: Note = notaDe()) -> NoteValues {
    NoteValues(nota, timeZone: zonaMadrid)
}

let baseCompleta = NotionDataSource(
    id: "ds-1", databaseTitle: "Diario", title: "Notas",
    properties: [
        NotionProperty(name: "Nombre", type: "title"),
        NotionProperty(name: "Fecha", type: "date"),
        NotionProperty(name: "Hablantes", type: "multi_select"),
        NotionProperty(name: "Duración", type: "number"),
        NotionProperty(name: "Clave", type: "rich_text"),
        NotionProperty(name: "Origen", type: "url"),
        NotionProperty(name: "Resumen", type: "rich_text"),
        NotionProperty(name: "Temas", type: "multi_select"),
        NotionProperty(name: "Estado", type: "select"),
        NotionProperty(name: "Hecho", type: "checkbox"),
    ])

func exportDe(
    _ source: NotionDataSource = baseCompleta, columnas: [String: String]? = nil, cuerpo: String = "{{transcripcion}}"
) -> NotionExport {
    NotionExport(source: source, columns: columnas ?? suggestedColumns(for: source), body: cuerpo)
}

func paginaDe(_ nota: Note = notaDe(), como export: NotionExport = exportDe(), audio: String? = nil) -> NotionPage {
    notionPage(for: nota, as: export, audio: audio, timeZone: zonaMadrid)
}
