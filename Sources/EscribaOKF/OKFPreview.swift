import Foundation
import EscribaCore

public struct OKFPreviewFile: Equatable, Sendable, Identifiable {
    public let documentID: String
    public let path: String
    public let contents: String

    public var id: String { documentID }
}

public func okfPreview(_ export: OKFExport, now: Date = Date(), timeZone: TimeZone = .current) -> [OKFPreviewFile] {
    let publication = okfPublication(
        sampleNote(recordedAt: now.addingTimeInterval(-2 * 3600)), as: export, in: BundleState(),
        producer: "escriba", now: now, timeZone: timeZone)
    let written = Dictionary(
        publication.changes.compactMap { change -> (String, String)? in
            guard case .write(let path, let contents) = change else { return nil }
            return (path, contents)
        },
        uniquingKeysWith: { _, last in last })
    return zip(export.documents, publication.paths).compactMap { document, path in
        written[path].map { OKFPreviewFile(documentID: document.id, path: path, contents: $0) }
    }
}

private func sampleNote(recordedAt: Date) -> Note {
    Note(
        recording: Recording(
            url: URL(fileURLWithPath: "/Notas de voz/Reunion del lanzamiento.m4a"),
            startedAt: recordedAt, key: "ejemplo"),
        transcript: Transcript(segments: [
            TranscriptSegment(start: 0, end: 8, speaker: "Ana", text: "¿Cómo vamos con el lanzamiento del jueves?"),
            TranscriptSegment(start: 8, end: 21, speaker: "Luis", text: "La migración no llega; propongo moverla una semana."),
            TranscriptSegment(start: 21, end: 29, speaker: "Ana", text: "Vale, y avisamos a soporte hoy mismo."),
        ]),
        digest: Digest(
            title: "Lanzamiento del jueves",
            summary: "Ana y Luis repasan el lanzamiento del jueves. Acuerdan mover la migración una semana y avisar hoy a soporte.",
            tags: ["lanzamiento", "migración"]))
}
