import Foundation
import Testing

@testable import EscribaKit

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
