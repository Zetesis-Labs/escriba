import Foundation
import GRDB
import EscribaCore

public enum RecordingStatus: String, Sendable, Codable, CaseIterable {
    case pending
    case processing
    case done
    case failed
    case discarded
}

struct RecordingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recording"

    var id: Int64?
    var key: String
    var sourcePath: String
    var audioPath: String
    var startedAt: Date
    var importedAt: Date
    var status: String
    var lastError: String?
    var currentTranscriptId: Int64?

    enum Columns {
        static let key = Column(CodingKeys.key)
        static let startedAt = Column(CodingKeys.startedAt)
        static let status = Column(CodingKeys.status)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func stored(
        in root: URL, transcript: TranscriptSummary? = nil, publications: [Publication] = []
    ) -> StoredRecording {
        let copy = audioPath.isEmpty ? nil : root.appending(path: audioPath)
        let files = FileManager.default
        let audio: AudioAvailability =
            if let copy, files.fileExists(atPath: copy.path(percentEncoded: false)) {
                .libraryCopy
            } else if files.fileExists(atPath: sourcePath) {
                .sourceOnly
            } else {
                .missing
            }

        return StoredRecording(
            key: key,
            sourceURL: URL(fileURLWithPath: sourcePath),
            audioURL: (audio == .libraryCopy ? copy : nil) ?? URL(fileURLWithPath: sourcePath),
            startedAt: startedAt,
            importedAt: importedAt,
            status: RecordingStatus(rawValue: status) ?? .done,
            lastError: lastError,
            audio: audio,
            transcript: transcript,
            publications: publications)
    }
}

struct TranscriptRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcript"

    var id: Int64?
    var recordingId: Int64
    var backend: String
    var createdAt: Date
    var text: String
    var language: String?
    var diarize: Bool
    var speakerCount: Int?
    var optionsKnown: Bool

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let recordingId = Column(CodingKeys.recordingId)
    }

    var options: TranscriptionOptions? {
        guard optionsKnown else { return nil }
        return TranscriptionOptions(language: language, diarize: diarize, speakerCount: speakerCount)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct SegmentRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segment"

    var transcriptId: Int64
    var position: Int
    var startTime: Double
    var endTime: Double
    var speaker: String?
    var text: String
    var words: [TranscriptWord]

    enum Columns {
        static let transcriptId = Column(CodingKeys.transcriptId)
        static let position = Column(CodingKeys.position)
    }

    init(transcriptId: Int64, position: Int, segment: TranscriptSegment) {
        self.transcriptId = transcriptId
        self.position = position
        startTime = segment.start
        endTime = segment.end
        speaker = segment.speaker
        text = segment.text
        words = segment.words
    }

    var segment: TranscriptSegment {
        TranscriptSegment(start: startTime, end: endTime, speaker: speaker, text: text, words: words)
    }
}

struct PublicationRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "publication"

    var id: Int64?
    var recordingId: Int64
    var connector: String
    var pageId: String?
    var url: String?
    var syncedAt: Date?
    var error: String?

    enum Columns {
        static let recordingId = Column(CodingKeys.recordingId)
        static let connector = Column(CodingKeys.connector)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var publication: Publication {
        Publication(
            connector: connector,
            pageId: pageId,
            url: url.flatMap(URL.init(string:)),
            syncedAt: syncedAt,
            error: error)
    }
}

func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
        try db.create(table: "recording") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("key", .text).notNull().unique()
            t.column("sourcePath", .text).notNull()
            t.column("audioPath", .text).notNull()
            t.column("startedAt", .datetime).notNull()
            t.column("importedAt", .datetime).notNull()
        }
        try db.create(table: "transcript") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("recording", onDelete: .cascade).notNull()
            t.column("backend", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("text", .text).notNull()
        }
        try db.create(table: "segment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("transcript", onDelete: .cascade).notNull()
            t.column("position", .integer).notNull()
            t.column("startTime", .double).notNull()
            t.column("endTime", .double).notNull()
            t.column("speaker", .text)
            t.column("text", .text).notNull()
            t.column("words", .text).notNull()
        }
    }
    migrator.registerMigration("v2-estados") { db in
        try db.alter(table: "recording") { t in
            t.add(column: "status", .text).notNull().defaults(to: "done")
            t.add(column: "lastError", .text)
        }
    }
    migrator.registerMigration("v3-notion") { db in
        try db.alter(table: "recording") { t in
            t.add(column: "notionPageId", .text)
            t.add(column: "notionURL", .text)
            t.add(column: "notionSyncedAt", .datetime)
            t.add(column: "notionError", .text)
        }
    }
    migrator.registerMigration("v4-conectores") { db in
        try db.create(table: "publication") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("recording", onDelete: .cascade).notNull()
            t.column("connector", .text).notNull()
            t.column("pageId", .text)
            t.column("url", .text)
            t.column("syncedAt", .datetime)
            t.column("error", .text)
            t.uniqueKey(["recordingId", "connector"])
        }
        try db.alter(table: "recording") { t in
            t.drop(column: "notionPageId")
            t.drop(column: "notionURL")
            t.drop(column: "notionSyncedAt")
            t.drop(column: "notionError")
        }
    }
    migrator.registerMigration("v5-versiones") { db in
        try db.alter(table: "transcript") { t in
            t.add(column: "language", .text)
            t.add(column: "diarize", .boolean).notNull().defaults(to: false)
            t.add(column: "speakerCount", .integer)
            t.add(column: "optionsKnown", .boolean).notNull().defaults(to: false)
        }
        try db.alter(table: "recording") { t in
            t.add(column: "currentTranscriptId", .integer)
        }
    }
    migrator.registerMigration("v5b-criterios-conocidos") { db in
        let columns = try db.columns(in: "transcript").map(\.name)
        guard !columns.contains("optionsKnown") else { return }
        try db.alter(table: "transcript") { t in
            t.add(column: "optionsKnown", .boolean).notNull().defaults(to: false)
        }
    }
    return migrator
}
