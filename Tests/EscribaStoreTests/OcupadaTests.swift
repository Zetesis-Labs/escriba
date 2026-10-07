#if canImport(SQLite3)
import Foundation
import SQLite3
import Testing

@testable import EscribaCore
@testable import EscribaStore

@Suite("Biblioteca: otra conexión escribiendo")
struct BibliotecaOcupadaTests {
    @Test("reabrir la biblioteca y registrar mientras otra conexión escribe espera a que termine")
    func reopensWhileAnotherWrites() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-ocupada-\(UUID().uuidString)")
        let root = base.appending(path: "library")
        _ = try Store(root: root)
        holdWriteLock(on: root.appending(path: "library.sqlite"), for: 0.3)

        let store = try Store(root: root)
        try await store.register([
            Recording(url: base.appending(path: "a.m4a"), startedAt: Date(), key: "2026-10-07/20-01-19"),
        ])

        #expect(try store.recordings().map(\.key) == ["2026-10-07/20-01-19"])
    }

    private func holdWriteLock(on path: URL, for seconds: Double) {
        var handle: OpaquePointer?
        sqlite3_open(path.path(percentEncoded: false), &handle)
        sqlite3_exec(handle, "BEGIN IMMEDIATE; CREATE TABLE ocupado (x);", nil, nil, nil)
        nonisolated(unsafe) let holder = handle
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            sqlite3_exec(holder, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(holder)
        }
    }
}
#endif
