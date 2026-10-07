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

    public var digest: Digest? { transcript?.digest }

    public var headline: String {
        guard let title = digest?.title, !title.isEmpty else { return self.title }
        return title
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
    public let digest: Digest?

    public init(
        backend: String, isSegmented: Bool, speakerCount: Int, version: Int = 1,
        versionCount: Int = 1, digest: Digest? = nil
    ) {
        self.backend = backend
        self.isSegmented = isSegmented
        self.speakerCount = speakerCount
        self.version = version
        self.versionCount = versionCount
        self.digest = digest
    }
}

public final class Store: Sendable {
    public let root: URL
    let writer: any DatabaseWriter

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root.appending(path: "audio"), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(
            path: root.appending(path: "library.sqlite").path(percentEncoded: false),
            configuration: configuration)
        try makeMigrator().migrate(pool)
        writer = pool
    }

    @discardableResult
    public func save(
        _ recording: Recording, _ transcript: Transcript, backend: String,
        options: TranscriptionOptions? = nil, digest: Digest? = nil
    ) throws -> StoredRecording {
        try write(recording, transcript, backend: backend, options: options, digest: digest).stored
    }

    private func write(
        _ recording: Recording, _ transcript: Transcript, backend: String,
        options: TranscriptionOptions?, digest: Digest?
    ) throws -> (stored: StoredRecording, version: Int64) {
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

            let version = try Self.insert(
                transcript, recordingId: recordingId, backend: backend, options: options,
                digest: digest, in: db)
            let count = try TranscriptRow.filter(TranscriptRow.Columns.recordingId == recordingId).fetchCount(db)
            let stored = row.stored(
                in: root,
                transcript: TranscriptSummary(
                    backend: backend,
                    isSegmented: transcript.isSegmented,
                    speakerCount: transcript.speakers.count,
                    version: count,
                    versionCount: count,
                    digest: digest))
            return (stored, version)
        }
    }

    public func addTranscript(
        _ transcript: Transcript, for key: String, backend: String,
        options: TranscriptionOptions? = nil, digest: Digest? = nil
    ) async throws {
        try await writer.write { db in
            try Self.attach(
                transcript, to: key, backend: backend, options: options, digest: digest, in: db)
        }
    }

    public func setDigest(_ digest: Digest?, for key: String, version: Int64? = nil) async throws {
        try await writer.write { db in
            guard let recordingId = try Self.recordingId(of: key, in: db) else {
                throw StoreError.unknownRecording(key)
            }
            guard var row = try Self.transcript(version, of: recordingId, in: db) else {
                throw StoreError.nothingToSummarize(key)
            }
            if let version, row.id != version { throw StoreError.unknownVersion(version, key) }
            row.carry(digest)
            try row.update(db)
        }
    }

    public func digest(for key: String) async throws -> Digest? {
        try await writer.read { db in try Self.currentTranscript(of: key, in: db)?.digest }
    }

    public func currentVersion(for key: String) async throws -> Int64? {
        try await writer.read { db in try Self.currentTranscript(of: key, in: db)?.id }
    }

    private static func currentTranscript(of key: String, in db: Database) throws -> TranscriptRow? {
        guard let recordingId = try recordingId(of: key, in: db) else { return nil }
        return try transcript(nil, of: recordingId, in: db)
    }

    private static func recordingId(of key: String, in db: Database) throws -> Int64? {
        try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db)?.id
    }

    private static func transcript(
        _ version: Int64?, of recordingId: Int64, in db: Database
    ) throws -> TranscriptRow? {
        var query = TranscriptRow.filter(TranscriptRow.Columns.recordingId == recordingId)
        if let wanted = try version ?? currentPointer(of: recordingId, in: db) {
            query = query.filter(TranscriptRow.Columns.id == wanted)
        }
        return try query.order(TranscriptRow.Columns.id.desc).fetchOne(db)
    }

    private static func currentPointer(of recordingId: Int64, in db: Database) throws -> Int64? {
        try RecordingRow.fetchOne(db, key: recordingId)?.currentTranscriptId
    }

    func attachTranscript(_ transcript: Transcript, for key: String, backend: String) throws {
        try writer.write { db in
            try Self.attach(transcript, to: key, backend: backend, options: nil, digest: nil, in: db)
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
        options: TranscriptionOptions?, digest: Digest?, in db: Database
    ) throws {
        guard
            var row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
            let recordingId = row.id
        else { throw StoreError.unknownRecording(key) }
        try Self.insert(
            transcript, recordingId: recordingId, backend: backend, options: options, digest: digest,
            in: db)
        row.currentTranscriptId = nil
        if row.status != RecordingStatus.discarded.rawValue {
            row.status = RecordingStatus.done.rawValue
            row.lastError = nil
        }
        try row.update(db)
    }

    @discardableResult
    private static func insert(
        _ transcript: Transcript, recordingId: Int64, backend: String,
        options: TranscriptionOptions?, digest: Digest?, in db: Database
    ) throws -> Int64 {
        var row = TranscriptRow(
            recordingId: recordingId, backend: backend, createdAt: Date(), text: transcript.text,
            language: options?.language, diarize: options?.diarize ?? false,
            speakerCount: options?.speakerCount, optionsKnown: options != nil,
            digestTitle: digest?.title, digestSummary: digest?.summary,
            digestTags: digest.map { encodedTags($0.tags) })
        try row.insert(db)
        guard let transcriptId = row.id else { throw StoreError.missingRowID }

        for (position, segment) in transcript.segments.enumerated() {
            try SegmentRow(transcriptId: transcriptId, position: position, segment: segment)
                .insert(db)
        }
        return transcriptId
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
        { note in
            try self.save(
                note.recording, note.transcript, backend: backend, options: options,
                digest: note.digest
            ).audioURL
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

    public static let runRetention: TimeInterval = 30 * 86_400

    public func saveRun(
        _ trace: RecipeTrace, for key: String, trigger: RecipeRunTrigger, now: Date = Date()
    ) async throws {
        let payload = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        let recipes = String(decoding: try JSONEncoder().encode(trace.recipes), as: UTF8.self)
        try await writer.write { db in
            guard let recordingId = try Self.recordingId(of: key, in: db) else {
                throw StoreError.unknownRecording(key)
            }
            if trace.outcome == .waiting {
                try db.execute(
                    sql: "DELETE FROM recipeRun WHERE recordingId = ? AND recipeKey = ? AND outcome = ?",
                    arguments: [recordingId, trace.recipe, RecipeRunOutcome.waiting.rawValue])
            }
            try db.execute(
                sql: """
                    INSERT INTO recipeRun (recordingId, recipeKey, recipes, trigger, outcome, startedAt, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    recordingId, trace.recipe, recipes, trigger.rawValue, trace.outcome.rawValue,
                    trace.startedAt ?? now, payload,
                ])
            try db.execute(
                sql: "DELETE FROM recipeRun WHERE startedAt < ?", arguments: [now.addingTimeInterval(-Self.runRetention)])
        }
    }

    public func latestTrace(for key: String) async throws -> RecipeTrace? {
        let payload = try await writer.read { db -> String? in
            guard let recordingId = try Self.recordingId(of: key, in: db) else { return nil }
            return try String.fetchOne(
                db,
                sql: """
                    SELECT payload FROM recipeRun WHERE recordingId = ? AND trigger <> ?
                    ORDER BY startedAt DESC, id DESC LIMIT 1
                    """,
                arguments: [recordingId, RecipeRunTrigger.test.rawValue])
        }
        return try payload.map { try JSONDecoder().decode(RecipeTrace.self, from: Data($0.utf8)) }
    }

    public func runs(_ filter: RecipeRunFilter) throws -> [RecipeRunRecord] {
        try writer.read { db in try fetchRuns(db, filter) }
    }

    public func observeRuns(_ filter: RecipeRunFilter) -> some AsyncSequence<[RecipeRunRecord], any Error> {
        ValueObservation
            .tracking { db in try fetchRuns(db, filter) }
            .removeDuplicates()
            .values(in: writer, scheduling: .task)
    }

    public func markDone(_ key: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET status = ?, lastError = NULL WHERE key = ? AND status <> ?",
                arguments: [
                    RecordingStatus.done.rawValue, key, RecordingStatus.discarded.rawValue,
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

    public func discardedRecordings() throws -> [DiscardedRecording] {
        try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT key, sourcePath FROM recording WHERE status = ?",
                arguments: [RecordingStatus.discarded.rawValue]
            ).map { row in DiscardedRecording(key: row[0], sourceURL: URL(fileURLWithPath: row[1])) }
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
            try Self.insert(
                transcript, recordingId: recordingId, backend: backend, options: nil, digest: nil,
                in: db)
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

    public func removePublication(key: String, connector: String) throws {
        try writer.write { db in
            guard let recording = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db),
                let recordingId = recording.id
            else { return }
            try PublicationRow
                .filter(PublicationRow.Columns.recordingId == recordingId)
                .filter(PublicationRow.Columns.connector == connector)
                .deleteAll(db)
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
            guard let chosen = try query.order(TranscriptRow.Columns.id.desc).fetchOne(db) else { return nil }
            return try Self.loadTranscript(chosen, in: db)
        }
    }

    private static func loadTranscript(_ row: TranscriptRow, in db: Database) throws -> Transcript {
        guard let transcriptId = row.id else { throw StoreError.missingRowID }
        let segments = try SegmentRow
            .filter(SegmentRow.Columns.transcriptId == transcriptId)
            .order(SegmentRow.Columns.position)
            .fetchAll(db)
        return segments.isEmpty
            ? Transcript(text: row.text)
            : Transcript(segments: segments.map(\.segment))
    }

    public func memory() -> NoteMemory {
        NoteMemory(
            recall: { recording, inputs in
                try await self.remembered(recording.key, matching: inputs)
            },
            keepTranscript: { recording, transcript, inputs in
                try self.write(
                    recording, transcript, backend: inputs.backend, options: inputs.options, digest: nil
                ).version
            },
            keepDigest: { recording, version, digest in
                try await self.setDigest(digest, for: recording.key, version: version)
            })
    }

    private func remembered(_ key: String, matching inputs: TranscriptionInputs) async throws -> Remembered? {
        try await writer.read { db in
            guard let recordingId = try Self.recordingId(of: key, in: db) else { return nil }
            let rows = try TranscriptRow
                .filter(TranscriptRow.Columns.recordingId == recordingId)
                .order(TranscriptRow.Columns.id.desc)
                .fetchAll(db)
            guard
                let row = rows.first(where: { inputs.matches(backend: $0.backend, options: $0.options) }),
                let version = row.id
            else { return nil }
            return Remembered(
                version: version, transcript: try Self.loadTranscript(row, in: db), digest: row.digest)
        }
    }

    public func audioCopySink() -> Sink {
        { note in
            guard let stored = try self.recording(for: note.recording.key) else {
                throw StoreError.unknownRecording(note.recording.key)
            }
            return stored.audioURL
        }
    }

    public func delete(key: String) throws {
        let root = root
        try writer.write { db in
            guard let row = try RecordingRow.filter(RecordingRow.Columns.key == key).fetchOne(db)
            else { return }
            try row.delete(db)
            Self.deleteAudioCopy(row, root: root)
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
                   t.digestTitle AS digestTitle, t.digestSummary AS digestSummary,
                   t.digestTags AS digestTags,
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
            versionCount: row["versionCount"],
            digest: digest(in: row))
    }
}

private func digest(in row: Row) -> Digest? {
    guard let title: String = row["digestTitle"], let summary: String = row["digestSummary"]
    else { return nil }
    return Digest(title: title, summary: summary, tags: decodedTags(row["digestTags"]))
}

public enum StoreError: Error, CustomStringConvertible {
    case missingRowID
    case unknownRecording(String)
    case unknownVersion(Int64, String)
    case nothingToSummarize(String)

    public var description: String {
        switch self {
        case .missingRowID: "SQLite no devolvio el id de la fila insertada"
        case .unknownRecording(let key): "no hay ninguna grabacion con clave \(key)"
        case .unknownVersion(let id, let key): "la version \(id) no es de la grabacion \(key)"
        case .nothingToSummarize(let key): "la grabacion \(key) aun no tiene transcripcion"
        }
    }
}

public struct RecipeRunFilter: Sendable, Equatable {
    public var recipe: String?
    public var outcome: RecipeRunOutcome?
    public var text: String
    public var limit: Int

    public init(recipe: String? = nil, outcome: RecipeRunOutcome? = nil, text: String = "", limit: Int = 200) {
        self.recipe = recipe
        self.outcome = outcome
        self.text = text
        self.limit = limit
    }
}

public struct RecipeRunRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let recordingKey: String
    public let trigger: RecipeRunTrigger
    public let startedAt: Date
    public let trace: RecipeTrace

    public init(id: Int64, recordingKey: String, trigger: RecipeRunTrigger, startedAt: Date, trace: RecipeTrace) {
        self.id = id
        self.recordingKey = recordingKey
        self.trigger = trigger
        self.startedAt = startedAt
        self.trace = trace
    }
}

private func fetchRuns(_ db: Database, _ filter: RecipeRunFilter) throws -> [RecipeRunRecord] {
    let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = "%\(text)%"
    let rows = try Row.fetchAll(
        db,
        sql: """
            SELECT run.id, recording.key, run.trigger, run.startedAt, run.payload
            FROM recipeRun AS run JOIN recording ON recording.id = run.recordingId
            WHERE (? IS NULL OR EXISTS (SELECT 1 FROM json_each(run.recipes) WHERE json_each.value = ?))
              AND (? IS NULL OR run.outcome = ?)
              AND (? = '' OR recording.key LIKE ? OR run.payload LIKE ?)
            ORDER BY run.startedAt DESC, run.id DESC
            LIMIT ?
            """,
        arguments: [
            filter.recipe, filter.recipe, filter.outcome?.rawValue, filter.outcome?.rawValue, text, pattern, pattern,
            filter.limit,
        ])
    return try rows.map { row in
        let payload: String = row[4]
        return RecipeRunRecord(
            id: row[0], recordingKey: row[1], trigger: RecipeRunTrigger(rawValue: row[2]) ?? .pipeline,
            startedAt: row[3], trace: try JSONDecoder().decode(RecipeTrace.self, from: Data(payload.utf8)))
    }
}

public struct DiscardedRecording: Sendable, Equatable {
    public let key: String
    public let sourceURL: URL

    public init(key: String, sourceURL: URL) {
        self.key = key
        self.sourceURL = sourceURL
    }
}
