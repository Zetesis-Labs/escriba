import Foundation
import EscribaCore

public struct LedgerPort: Sendable {
    public var settledKeys: @Sendable () throws -> Set<String>
    public var markDone: @Sendable (_ key: String, _ source: URL, _ output: URL) throws -> Void
    public var markFailed: @Sendable (_ key: String, _ source: URL, _ error: String) throws -> Void

    public init(
        settledKeys: @escaping @Sendable () throws -> Set<String>,
        markDone: @escaping @Sendable (String, URL, URL) throws -> Void,
        markFailed: @escaping @Sendable (String, URL, String) throws -> Void
    ) {
        self.settledKeys = settledKeys
        self.markDone = markDone
        self.markFailed = markFailed
    }
}
