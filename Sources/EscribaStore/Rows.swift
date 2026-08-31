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

    enum Columns {
        static let key = Column(CodingKeys.key)
        static let startedAt = Column(CodingKeys.startedAt)
        static let status = Column(CodingKeys.status)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func stored(in root: URL, transcript: TranscriptSummary? = nil) -> StoredRecording {
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
            transcript: transcript)
    }
}

struct TranscriptRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcript"

    var id: Int64?
    var recordingId: Int64
    var backend: String
    var createdAt: Date
    var text: String

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let recordingId = Column(CodingKeys.recordingId)
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
    return migrator
}
