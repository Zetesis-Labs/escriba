import Foundation

public struct FolderWatch: Sendable {
    public let stop: @Sendable () -> Void

    public init(stop: @escaping @Sendable () -> Void) {
        self.stop = stop
    }
}

public typealias FolderWatcher = @Sendable (URL, @escaping @Sendable () -> Void) -> FolderWatch

public let noWatcher: FolderWatcher = { _, _ in FolderWatch(stop: {}) }
