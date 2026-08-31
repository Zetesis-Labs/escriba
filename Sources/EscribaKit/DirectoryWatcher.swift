import CoreServices
import Foundation

public final class DirectoryWatcher: @unchecked Sendable {
    private let root: URL
    private let onRelevantChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.ruben.escriba.fsevents")
    private var stream: FSEventStreamRef?

    public init(root: URL, onRelevantChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.onRelevantChange = onRelevantChange
    }

    public func start() {
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

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
