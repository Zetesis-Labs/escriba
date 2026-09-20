import Foundation
import Synchronization
import EscribaEngine

#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct LedgerRecord: Sendable {
    public let key: String
    public let sourcePath: String
    public let outputPath: String?

    public init(key: String, sourcePath: String, outputPath: String?) {
        self.key = key
        self.sourcePath = sourcePath
        self.outputPath = outputPath
    }
}

public struct LedgerFailure: Sendable {
    public let key: String
    public let attempts: Int
    public let error: String
}

public final class Ledger: @unchecked Sendable {
    public static let maxAttempts = 5
    public static let retryBackoff: TimeInterval = 600

    public var port: LedgerPort {
        LedgerPort(
            settledKeys: { try self.settledKeys() },
            markDone: { key, source, output in try self.markDone(key: key, source: source, output: output) },
            markFailed: { key, source, error in try self.markFailed(key: key, source: source, error: error) })
    }

    private let db: OpaquePointer
    private let lock = Mutex(())

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(path.path(percentEncoded: false), &handle) == SQLITE_OK,
              let handle
        else { throw LedgerError.cannotOpen(path.path(percentEncoded: false)) }
        db = handle

        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS transcriptions (
                key TEXT PRIMARY KEY,
                source_path TEXT NOT NULL,
                output_path TEXT,
                status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                updated_at REAL NOT NULL
            )
            """)
    }

    deinit { sqlite3_close(db) }

    public func settledKeys(now: Date = Date()) throws -> Set<String> {
        try lock.withLock { _ in
            let sql = """
                SELECT key FROM transcriptions
                WHERE status = 'done'
                   OR (status = 'failed' AND attempts >= ?)
                   OR (status = 'failed' AND updated_at > ?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LedgerError.query(lastMessage)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(Self.maxAttempts))
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970 - Self.retryBackoff)

            var keys: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    keys.insert(String(cString: text))
                }
            }
            return keys
        }
    }

    public func markDone(key: String, source: URL, output: URL) throws {
        try write("""
            INSERT INTO transcriptions (key, source_path, output_path, status, attempts, updated_at)
            VALUES (?, ?, ?, 'done', 1, ?)
            ON CONFLICT(key) DO UPDATE SET
                output_path = excluded.output_path,
                status = 'done',
                attempts = transcriptions.attempts + 1,
                last_error = NULL,
                updated_at = excluded.updated_at
            """) { statement in
            bind(statement, 1, key)
            bind(statement, 2, source.path(percentEncoded: false))
            bind(statement, 3, output.path(percentEncoded: false))
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        }
    }

    public func markFailed(key: String, source: URL, error: String) throws {
        try write("""
            INSERT INTO transcriptions (key, source_path, status, attempts, last_error, updated_at)
            VALUES (?, ?, 'failed', 1, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                status = 'failed',
                attempts = transcriptions.attempts + 1,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at
            """) { statement in
            bind(statement, 1, key)
            bind(statement, 2, source.path(percentEncoded: false))
            bind(statement, 3, String(error.prefix(2000)))
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        }
    }

    public func counts() throws -> [String: Int] {
        try lock.withLock { _ in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT status, COUNT(*) FROM transcriptions GROUP BY status", -1, &statement,
                nil) == SQLITE_OK
            else { throw LedgerError.query(lastMessage) }
            defer { sqlite3_finalize(statement) }

            var result: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let status = sqlite3_column_text(statement, 0) {
                    result[String(cString: status)] = Int(sqlite3_column_int(statement, 1))
                }
            }
            return result
        }
    }

    public func failures() throws -> [LedgerFailure] {
        try lock.withLock { _ in
            let sql = """
                SELECT key, attempts, COALESCE(last_error, '') FROM transcriptions
                WHERE status = 'failed' ORDER BY updated_at DESC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LedgerError.query(lastMessage)
            }
            defer { sqlite3_finalize(statement) }

            var result: [LedgerFailure] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0),
                      let error = sqlite3_column_text(statement, 2)
                else { continue }
                result.append(
                    LedgerFailure(
                        key: String(cString: key),
                        attempts: Int(sqlite3_column_int(statement, 1)),
                        error: String(cString: error)))
            }
            return result
        }
    }

    public func doneRecords() throws -> [LedgerRecord] {
        try lock.withLock { _ in
            let sql = """
                SELECT key, source_path, output_path FROM transcriptions
                WHERE status = 'done' ORDER BY key
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LedgerError.query(lastMessage)
            }
            defer { sqlite3_finalize(statement) }

            var result: [LedgerRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0),
                      let source = sqlite3_column_text(statement, 1)
                else { continue }
                result.append(
                    LedgerRecord(
                        key: String(cString: key),
                        sourcePath: String(cString: source),
                        outputPath: sqlite3_column_text(statement, 2).map { String(cString: $0) }))
            }
            return result
        }
    }

    private func write(_ sql: String, bindings: (OpaquePointer) -> Void) throws {
        try lock.withLock { _ in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
            else { throw LedgerError.query(lastMessage) }
            defer { sqlite3_finalize(statement) }

            bindings(statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LedgerError.query(lastMessage)
            }
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LedgerError.query(lastMessage)
        }
    }

    private var lastMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
}

public enum LedgerError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case query(String)

    public var description: String {
        switch self {
        case .cannotOpen(let path): "no se pudo abrir el ledger en \(path)"
        case .query(let message): "error de SQLite: \(message)"
        }
    }
}
