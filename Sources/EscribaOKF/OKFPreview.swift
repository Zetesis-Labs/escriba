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
