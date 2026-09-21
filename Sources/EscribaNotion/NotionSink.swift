#if !os(WASI)
import Foundation
import EscribaCore
import EscribaEngine

public struct NotionJournal: Sendable {
    public var known: @Sendable (String) throws -> NotionPageRef?
    public var published: @Sendable (String, NotionPageRef, Date) -> Void
    public var failed: @Sendable (String, String) -> Void

    public init(
        known: @escaping @Sendable (String) throws -> NotionPageRef? = { _ in nil },
        published: @escaping @Sendable (String, NotionPageRef, Date) -> Void,
        failed: @escaping @Sendable (String, String) -> Void
    ) {
        self.known = known
        self.published = published
        self.failed = failed
    }

    public static let silent = NotionJournal(published: { _, _, _ in }, failed: { _, _ in })
}

public func notionSink(
    export: NotionExport,
    client: NotionClient,
    journal: NotionJournal = .silent,
    timeZone: TimeZone = .current,
    now: @escaping @Sendable () -> Date = Date.init
) -> Sink {
    { recording, transcript in
        let known: NotionPageRef?
        do {
            known = try journal.known(recording.key)
        } catch {
            let problem = "no se pudo consultar si ya estaba publicado: \(error)"
            journal.failed(recording.key, problem)
            Log.error("\(recording.key) no se publico en Notion: \(problem)")
            return recording.url
        }
        do {
            let page = try await publish(
                recording, transcript, as: export, using: client,
                known: known, timeZone: timeZone)
            journal.published(recording.key, page, now())
            Log.info("\(recording.key) publicado en Notion")
            return page.url ?? recording.url
        } catch let error as NotionError {
            journal.failed(recording.key, error.message)
            Log.error("\(recording.key) no se publico en Notion: \(error.message)")
            return recording.url
        }
    }
}
#endif
