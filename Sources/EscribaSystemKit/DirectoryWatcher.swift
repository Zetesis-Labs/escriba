#if os(macOS)
import CoreServices
import Foundation
import Synchronization

public final class DirectoryWatcher: Sendable {
    private let root: URL
    private let onRelevantChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.ruben.escriba.fsevents")
    private let stream = Mutex<FSEventStreamRef?>(nil)

    public init(root: URL, onRelevantChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.onRelevantChange = onRelevantChange
    }

    public func start() {
        let previous = stream.withLock { current -> FSEventStreamRef? in
            guard let created = createStream() else { return nil }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            defer { current = created }
            return current
        }
        previous.map(release)
    }

    private func createStream() -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()

            let cPaths = paths.bindMemory(to: UnsafePointer<CChar>.self, capacity: count)
            for index in 0..<count where String(cString: cPaths[index]).lowercased().hasSuffix(".m4a") {
                watcher.onRelevantChange()
                return
            }
        }

        return FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
    }

    public func stop() {
        let current = stream.withLock { current in
            defer { current = nil }
            return current
        }
        current.map(release)
    }

    private func release(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#endif
