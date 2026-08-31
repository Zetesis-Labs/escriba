import Foundation
import GRDB
import EscribaCore
import EscribaKit

public struct StoredRecording: Sendable, Equatable, Identifiable {
    public let key: String
    public let sourceURL: URL
    public let audioURL: URL
    public let startedAt: Date
    public let importedAt: Date

    public var id: String { key }
}

public final class Store: Sendable {
    public let root: URL
    let writer: any DatabaseWriter

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root.appending(path: "audio"), withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: root.appending(path: "library.sqlite").path(percentEncoded: false))
        try makeMigrator().migrate(pool)
        writer = pool
    }

    @discardableResult
    public func save(
        _ recording: Recording, _ transcript: Transcript, backend: String
    ) throws -> StoredRecording {
        let audioPath = "audio/\(recording.key).\(recording.url.pathExtension)"
        try copyAudio(from: recording.url, to: root.appending(path: audioPath))
        let now = Date()
        let root = root

        return try writer.write { db in
            var row = try RecordingRow.filter(RecordingRow.Columns.key == recording.key).fetchOne(db)
                ?? RecordingRow(
                    key: recording.key,
                    sourcePath: recording.url.path(percentEncoded: false),
                    audioPath: audioPath,
                    startedAt: recording.startedAt,
                    importedAt: now)
            if row.id == nil { try row.insert(db) }
            guard let recordingId = row.id else { throw StoreError.missingRowID }

            try Self.insert(transcript, recordingId: recordingId, backend: backend, in: db)
            return row.stored(in: root)
        }
    }

    public func addTranscript(
        _ transcript: Transcript, for key: String, backend: String
    ) throws {
        try writer.write { db in
            guard
                let row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = row.id
            else { throw StoreError.unknownRecording(key) }
            try Self.insert(transcript, recordingId: recordingId, backend: backend, in: db)
        }
    }

    private static func insert(
        _ transcript: Transcript, recordingId: Int64, backend: String, in db: Database
    ) throws {
        var row = TranscriptRow(
            recordingId: recordingId, backend: backend, createdAt: Date(), text: transcript.text)
        try row.insert(db)
        guard let transcriptId = row.id else { throw StoreError.missingRowID }

        for (position, segment) in transcript.segments.enumerated() {
            try SegmentRow(transcriptId: transcriptId, position: position, segment: segment)
                .insert(db)
        }
    }

    func transcriptCount(for key: String) throws -> Int {
        try writer.read { db in
            guard
                let row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = row.id
            else { return 0 }
            return try TranscriptRow.filter(TranscriptRow.Columns.recordingId == recordingId)
                .fetchCount(db)
        }
    }

    public func sink(backend: String) -> Sink {
        { recording, transcript in
            try self.save(recording, transcript, backend: backend).audioURL
        }
    }

    public func recordings() throws -> [StoredRecording] {
        let root = root
        return try writer.read { db in try fetchRecordings(db, root: root) }
    }

    public func count() throws -> Int {
        try writer.read { db in try RecordingRow.fetchCount(db) }
    }

    public func transcript(for key: String) throws -> Transcript? {
        try writer.read { db in
            guard
                let recording = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = recording.id,
                let latest = try TranscriptRow
                    .filter(TranscriptRow.Columns.recordingId == recordingId)
                    .order(TranscriptRow.Columns.id.desc)
                    .fetchOne(db),
                let transcriptId = latest.id
            else { return nil }

            let segments = try SegmentRow
                .filter(SegmentRow.Columns.transcriptId == transcriptId)
                .order(SegmentRow.Columns.position)
                .fetchAll(db)
            return segments.isEmpty
                ? Transcript(text: latest.text)
                : Transcript(segments: segments.map(\.segment))
        }
    }

    public func delete(key: String) throws {
        let root = root
        try writer.write { db in
            guard let row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db)
            else { return }
            try row.delete(db)
            let audio = root.appending(path: row.audioPath)
            if FileManager.default.fileExists(atPath: audio.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: audio)
            }
        }
    }

    public func observeRecordings() -> some AsyncSequence<[StoredRecording], any Error> {
        let root = root
        return ValueObservation
            .tracking { db in try fetchRecordings(db, root: root) }
            .values(in: writer, scheduling: .task)
    }

    func orphanRows() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT (SELECT COUNT(*) FROM transcript t
                            WHERE NOT EXISTS (SELECT 1 FROM recording r WHERE r.id = t.recordingId))
                         + (SELECT COUNT(*) FROM segment s
                            WHERE NOT EXISTS (SELECT 1 FROM transcript t WHERE t.id = s.transcriptId))
                    """) ?? 0
        }
    }

    private func copyAudio(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        guard source.resolvingSymlinksInPath().path() != destination.resolvingSymlinksInPath().path()
        else { return }
        try files.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            try files.removeItem(at: destination)
        }
        try files.copyItem(at: source, to: destination)
    }
}

private func fetchRecordings(_ db: Database, root: URL) throws -> [StoredRecording] {
    try RecordingRow
        .order(RecordingRow.Columns.startedAt.desc)
        .fetchAll(db)
        .map { $0.stored(in: root) }
}

public enum StoreError: Error, CustomStringConvertible {
    case missingRowID
    case unknownRecording(String)

    public var description: String {
        switch self {
        case .missingRowID: "SQLite no devolvio el id de la fila insertada"
        case .unknownRecording(let key): "no hay ninguna grabacion con clave \(key)"
        }
    }
}
