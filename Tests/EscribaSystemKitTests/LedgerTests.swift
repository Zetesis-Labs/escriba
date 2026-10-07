import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

@testable import EscribaEngine
@testable import EscribaSystemKit

@Suite("Ledger: registros hechos con sus rutas")
struct LedgerDoneRecordsTests {
    @Test("devuelve clave, origen y salida de lo hecho, y omite lo fallido")
    func doneRecords() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-ledger-tests-\(UUID().uuidString)")
        let ledger = try Ledger(path: base.appending(path: "ledger.db"))

        try ledger.markDone(
            key: "2026-08-31/09-00-00",
            source: URL(fileURLWithPath: "/origen/a.m4a"),
            output: URL(fileURLWithPath: "/salida/a.txt"))
        try ledger.markFailed(
            key: "2026-08-31/10-00-00",
            source: URL(fileURLWithPath: "/origen/b.m4a"),
            error: "se rompio")

        let records = try ledger.doneRecords()

        #expect(records.map(\.key) == ["2026-08-31/09-00-00"])
        #expect(records.first?.sourcePath == "/origen/a.m4a")
        #expect(records.first?.outputPath == "/salida/a.txt")
    }
}

@Suite("Ledger: otra conexión ocupada")
struct LedgerBusyTests {
    @Test("abrir el ledger mientras otra conexión lo tiene en exclusiva espera a que lo suelte")
    func opensWhileAnotherHoldsIt() throws {
        let path = try freshLedgerPath()
        _ = try Ledger(path: path)
        holdLock(on: path, exclusive: true, for: .milliseconds(300))

        let ledger = try Ledger(path: path)

        #expect(try ledger.counts().isEmpty)
    }

    @Test("escribir mientras otra conexión escribe espera a que termine")
    func writesWhileAnotherWrites() throws {
        let path = try freshLedgerPath()
        let ledger = try Ledger(path: path)
        holdLock(on: path, exclusive: false, for: .milliseconds(300))

        try ledger.markDone(
            key: "2026-10-07/20-01-19",
            source: URL(fileURLWithPath: "/origen/a.m4a"),
            output: URL(fileURLWithPath: "/salida/a.m4a"))

        #expect(try ledger.doneRecords().map(\.key) == ["2026-10-07/20-01-19"])
    }

    private func freshLedgerPath() throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-ledger-busy-\(UUID().uuidString)")
            .appending(path: "ledger.db")
    }

    private func holdLock(on path: URL, exclusive: Bool, for duration: Duration) {
        var handle: OpaquePointer?
        sqlite3_open(path.path(percentEncoded: false), &handle)
        let locking = exclusive ? "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;" : "BEGIN IMMEDIATE;"
        sqlite3_exec(
            handle,
            "\(locking) INSERT INTO transcriptions (key, source_path, status, updated_at) VALUES ('ocupado', '/x', 'failed', 0);",
            nil, nil, nil)
        nonisolated(unsafe) let holder = handle
        let seconds = Double(duration.components.attoseconds) / 1e18 + Double(duration.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            sqlite3_exec(holder, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(holder)
        }
    }
}
