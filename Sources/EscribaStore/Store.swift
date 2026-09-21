import Foundation
import GRDB
import EscribaCore
import EscribaEngine
import EscribaSystemKit

public struct StoredRecording: Sendable, Equatable, Identifiable {
    public let key: String
    public let sourceURL: URL
    public let audioURL: URL
    public let startedAt: Date
    public let importedAt: Date
    public let status: RecordingStatus
    public let lastError: String?
    public let audio: AudioAvailability
    public let transcript: TranscriptSummary?
    public let publications: [Publication]

    public init(
        key: String,
        sourceURL: URL,
        audioURL: URL,
        startedAt: Date,
        importedAt: Date,
        status: RecordingStatus,
        lastError: String?,
        audio: AudioAvailability,
        transcript: TranscriptSummary?,
        publications: [Publication] = []
    ) {
        self.key = key
        self.sourceURL = sourceURL
        self.audioURL = audioURL
        self.startedAt = startedAt
        self.importedAt = importedAt
        self.status = status
        self.lastError = lastError
        self.audio = audio
        self.transcript = transcript
        self.publications = publications
    }

    public var id: String { key }

    public func publication(in connector: String) -> Publication? {
        publications.first { $0.connector == connector }
    }

    public var title: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }
}

public struct Publication: Sendable, Equatable {
    public let connector: String
    public let pageId: String?
    public let url: URL?
    public let syncedAt: Date?
    public let error: String?

    public init(connector: String, pageId: String?, url: URL?, syncedAt: Date?, error: String?) {
        self.connector = connector
        self.pageId = pageId
        self.url = url
        self.syncedAt = syncedAt
        self.error = error
    }

    public var isPublished: Bool { pageId != nil }
}

public enum AudioAvailability: String, Sendable, Equatable {
    case libraryCopy
    case sourceOnly
    case missing
}

public struct TranscriptVersion: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let number: Int
    public let backend: String
    public let createdAt: Date
    public let options: TranscriptionOptions?
    public let isCurrent: Bool

    public init(
        id: Int64, number: Int, backend: String, createdAt: Date,
        options: TranscriptionOptions?, isCurrent: Bool
    ) {
        self.id = id
        self.number = number
        self.backend = backend
        self.createdAt = createdAt
        self.options = options
        self.isCurrent = isCurrent
    }

    public var label: String {
        "v\(number) · \(options?.label ?? "criterios desconocidos")"
    }
}

public struct TranscriptSummary: Sendable, Equatable {
    public let backend: String
    public let isSegmented: Bool
    public let speakerCount: Int
    public let version: Int
    public let versionCount: Int

    public init(
        backend: String, isSegmented: Bool, speakerCount: Int, version: Int = 1, versionCount: Int = 1
    ) {
        self.backend = backend
        self.isSegmented = isSegmented
        self.speakerCount = speakerCount
        self.version = version
        self.versionCount = versionCount
    }
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
        _ recording: Recording, _ transcript: Transcript, backend: String,
        options: TranscriptionOptions? = nil
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
                    importedAt: now,
                    status: RecordingStatus.done.rawValue,
                    lastError: nil)
            if row.id == nil {
                try row.insert(db)
            } else {
                row.audioPath = audioPath
                row.currentTranscriptId = nil
                if row.status != RecordingStatus.discarded.rawValue {
                    row.status = RecordingStatus.done.rawValue
                    row.lastError = nil
                }
                try row.update(db)
            }
            guard let recordingId = row.id else { throw StoreError.missingRowID }

            try Self.insert(transcript, recordingId: recordingId, backend: backend, options: options, in: db)
            let count = try TranscriptRow.filter(TranscriptRow.Columns.recordingId == recordingId).fetchCount(db)
            return row.stored(
                in: root,
                transcript: TranscriptSummary(
                    backend: backend,
                    isSegmented: transcript.isSegmented,
                    speakerCount: transcript.speakers.count,
                    version: count,
                    versionCount: count))
        }
    }

    public func addTranscript(
        _ transcript: Transcript, for key: String, backend: String,
        options: TranscriptionOptions? = nil
    ) async throws {
        try await writer.write { db in
            try Self.attach(transcript, to: key, backend: backend, options: options, in: db)
        }
    }

    func attachTranscript(_ transcript: Transcript, for key: String, backend: String) throws {
        try writer.write { db in
            try Self.attach(transcript, to: key, backend: backend, options: nil, in: db)
        }
    }

    public func versions(for key: String) async throws -> [TranscriptVersion] {
        try await writer.read { db in
            guard
                let recording = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = recording.id
            else { return [] }
            let rows = try TranscriptRow
                .filter(TranscriptRow.Columns.recordingId == recordingId)
                .order(TranscriptRow.Columns.id)
                .fetchAll(db)
            let current = recording.currentTranscriptId ?? rows.last?.id
            return rows.enumerated().compactMap { index, row in
                row.id.map {
                    TranscriptVersion(
                        id: $0, number: index + 1, backend: row.backend, createdAt: row.createdAt,
                        options: row.options, isCurrent: $0 == current)
                }
            }
        }
    }

    public func choose(version id: Int64, for key: String) async throws {
        try await writer.write { db in
            guard
                var row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = row.id
            else { throw StoreError.unknownRecording(key) }
            let owned = try TranscriptRow
                .filter(TranscriptRow.Columns.recordingId == recordingId)
                .filter(TranscriptRow.Columns.id == id)
                .fetchCount(db)
            guard owned == 1 else { throw StoreError.unknownVersion(id, key) }
            row.currentTranscriptId = id
            try row.update(db)
        }
    }

    private static func attach(
        _ transcript: Transcript, to key: String, backend: String,
        options: TranscriptionOptions?, in db: Database
    ) throws {
        guard
            var row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
            let recordingId = row.id
        else { throw StoreError.unknownRecording(key) }
        try Self.insert(transcript, recordingId: recordingId, backend: backend, options: options, in: db)
        row.currentTranscriptId = nil
        if row.status != RecordingStatus.discarded.rawValue {
            row.status = RecordingStatus.done.rawValue
            row.lastError = nil
        }
        try row.update(db)
    }

    private static func insert(
        _ transcript: Transcript, recordingId: Int64, backend: String,
        options: TranscriptionOptions?, in db: Database
    ) throws {
        var row = TranscriptRow(
            recordingId: recordingId, backend: backend, createdAt: Date(), text: transcript.text,
            language: options?.language, diarize: options?.diarize ?? false,
            speakerCount: options?.speakerCount, optionsKnown: options != nil)
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

    public func sink(backend: String, options: TranscriptionOptions? = nil) -> Sink {
        { recording, transcript in
            try self.save(recording, transcript, backend: backend, options: options).audioURL
        }
    }

    public func register(_ recordings: [Recording]) async throws {
        guard !recordings.isEmpty else { return }
        try await writer.write { db in
            for recording in recordings {
                let exists = try RecordingRow
                    .filter(RecordingRow.Columns.key == recording.key)
                    .fetchCount(db) > 0
                guard !exists else { continue }
                var row = RecordingRow(
                    key: recording.key,
                    sourcePath: recording.url.path(percentEncoded: false),
                    audioPath: "",
                    startedAt: recording.startedAt,
                    importedAt: Date(),
                    status: RecordingStatus.pending.rawValue,
                    lastError: nil)
                try row.insert(db)
            }
        }
    }

    public func markProcessing(_ key: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET status = ? WHERE key = ? AND status NOT IN (?, ?)",
                arguments: [
                    RecordingStatus.processing.rawValue, key,
                    RecordingStatus.done.rawValue, RecordingStatus.discarded.rawValue,
                ])
        }
    }

    public func markFailed(_ key: String, error: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET status = ?, lastError = ? WHERE key = ? AND status <> ?",
                arguments: [
                    RecordingStatus.failed.rawValue, String(error.prefix(2000)), key,
                    RecordingStatus.discarded.rawValue,
                ])
        }
    }

    public func resetInterrupted() throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET status = ? WHERE status = ?",
                arguments: [RecordingStatus.pending.rawValue, RecordingStatus.processing.rawValue])
        }
    }

    public func discard(key: String) async throws {
        let root = root
        try await writer.write { db in
            guard var row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                  let recordingId = row.id
            else { return }
            try db.execute(
                sql: "DELETE FROM transcript WHERE recordingId = ?", arguments: [recordingId])
            Self.deleteAudioCopy(row, root: root)
            row.audioPath = ""
            row.status = RecordingStatus.discarded.rawValue
            row.lastError = nil
            try row.update(db)
        }
    }

    public func removeAudio(key: String) async throws {
        let root = root
        try await writer.write { db in
            guard var row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db)
            else { return }
            Self.deleteAudioCopy(row, root: root)
            row.audioPath = ""
            try row.update(db)
        }
    }

    private static func deleteAudioCopy(_ row: RecordingRow, root: URL) {
        guard !row.audioPath.isEmpty else { return }
        let copy = root.appending(path: row.audioPath)
        guard FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: copy)
        } catch {
            Log.error("no se pudo borrar la copia de audio \(row.audioPath): \(error)")
        }
    }

    func status(for key: String) throws -> RecordingStatus? {
        try writer.read { db in
            try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db)
                .flatMap { RecordingStatus(rawValue: $0.status) }
        }
    }

    func knows(_ key: String) throws -> Bool {
        try writer.read { db in
            try RecordingRow.filter(RecordingRow.Columns.key == key).fetchCount(db) > 0
        }
    }

    func insertDoneWithoutAudio(
        _ recording: Recording, _ transcript: Transcript, backend: String
    ) throws {
        try writer.write { db in
            var row = RecordingRow(
                key: recording.key,
                sourcePath: recording.url.path(percentEncoded: false),
                audioPath: "",
                startedAt: recording.startedAt,
                importedAt: Date(),
                status: RecordingStatus.done.rawValue,
                lastError: nil)
            try row.insert(db)
            guard let recordingId = row.id else { throw StoreError.missingRowID }
            try Self.insert(transcript, recordingId: recordingId, backend: backend, options: nil, in: db)
        }
    }

    public func recording(for key: String) throws -> StoredRecording? {
        let root = root
        return try writer.read { db in
            let summaries = try latestSummaries(db)
            guard let row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let id = row.id
            else { return nil }
            return row.stored(
                in: root, transcript: summaries[id], publications: try publications(db)[id] ?? [])
        }
    }

    public func markPublished(
        key: String, connector: String, pageId: String, url: URL?, at moment: Date
    ) throws {
        try upsertPublication(key: key, connector: connector) { row in
            row.pageId = pageId
            row.url = url?.absoluteString
            row.syncedAt = moment
            row.error = nil
        }
    }

    public func markPublishFailed(key: String, connector: String, error: String) throws {
        try upsertPublication(key: key, connector: connector) { row in
            row.error = String(error.prefix(2000))
        }
    }

    private func upsertPublication(
        key: String, connector: String, _ change: (inout PublicationRow) -> Void
    ) throws {
        try writer.write { db in
            guard let recording = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = recording.id
            else { return }

            var row = try PublicationRow
                .filter(PublicationRow.Columns.recordingId == recordingId)
                .filter(PublicationRow.Columns.connector == connector)
                .fetchOne(db)
                ?? PublicationRow(recordingId: recordingId, connector: connector)
            change(&row)
            try row.save(db)
        }
    }

    public func recordings() throws -> [StoredRecording] {
        let root = root
        return try writer.read { db in try fetchRecordings(db, root: root) }
    }

    public func count() throws -> Int {
        try writer.read { db in
            try RecordingRow
                .filter(RecordingRow.Columns.status != RecordingStatus.discarded.rawValue)
                .fetchCount(db)
        }
    }

    public func transcript(for key: String, version: Int64? = nil) async throws -> Transcript? {
        try await writer.read { db in
            guard
                let recording = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = recording.id
            else { return nil }
            var query = TranscriptRow.filter(TranscriptRow.Columns.recordingId == recordingId)
            if let wanted = version ?? recording.currentTranscriptId {
                query = query.filter(TranscriptRow.Columns.id == wanted)
            }
            guard
                let chosen = try query.order(TranscriptRow.Columns.id.desc).fetchOne(db),
                let transcriptId = chosen.id
            else { return nil }

            let segments = try SegmentRow
                .filter(SegmentRow.Columns.transcriptId == transcriptId)
                .order(SegmentRow.Columns.position)
                .fetchAll(db)
            return segments.isEmpty
                ? Transcript(text: chosen.text)
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
            .removeDuplicates()
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
    let summaries = try latestSummaries(db)
    let published = try publications(db)
    return try RecordingRow
        .filter(RecordingRow.Columns.status != RecordingStatus.discarded.rawValue)
        .order(RecordingRow.Columns.startedAt.desc)
        .fetchAll(db)
        .map { row in
            row.stored(
                in: root,
                transcript: row.id.flatMap { summaries[$0] },
                publications: row.id.flatMap { published[$0] } ?? [])
        }
}

private func publications(_ db: Database) throws -> [Int64: [Publication]] {
    Dictionary(grouping: try PublicationRow.fetchAll(db), by: \.recordingId)
        .mapValues { $0.map(\.publication) }
}

private func latestSummaries(_ db: Database) throws -> [Int64: TranscriptSummary] {
    try Row.fetchAll(
        db,
        sql: """
            SELECT t.recordingId AS recordingId, t.backend AS backend,
                   COUNT(s.id) AS segments, COUNT(DISTINCT s.speaker) AS speakers,
                   (SELECT COUNT(*) FROM transcript v WHERE v.recordingId = r.id AND v.id <= t.id) AS version,
                   (SELECT COUNT(*) FROM transcript v WHERE v.recordingId = r.id) AS versionCount
            FROM recording r
            JOIN transcript t
              ON t.id = COALESCE(
                    r.currentTranscriptId,
                    (SELECT MAX(id) FROM transcript WHERE recordingId = r.id))
            LEFT JOIN segment s ON s.transcriptId = t.id
            GROUP BY t.id
            """
    ).reduce(into: [:]) { summaries, row in
        summaries[row["recordingId"]] = TranscriptSummary(
            backend: row["backend"],
            isSegmented: row["segments"] as Int > 0,
            speakerCount: row["speakers"],
            version: row["version"],
            versionCount: row["versionCount"])
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case missingRowID
    case unknownRecording(String)
    case unknownVersion(Int64, String)

    public var description: String {
        switch self {
        case .missingRowID: "SQLite no devolvio el id de la fila insertada"
        case .unknownRecording(let key): "no hay ninguna grabacion con clave \(key)"
        case .unknownVersion(let id, let key): "la version \(id) no es de la grabacion \(key)"
        }
    }
}
