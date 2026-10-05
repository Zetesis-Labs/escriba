import Foundation

public struct Inbox: Sendable {
    public let root: URL
    public var names: @Sendable () throws -> Set<String>
    public var importFile: @Sendable (URL, String) throws -> Void
    public var recordingURL: @Sendable () throws -> URL
    public var finishRecording: @Sendable (URL, String, Date) throws -> Void
    public var discardRecording: @Sendable (URL) -> Void

    public init(
        root: URL,
        names: @escaping @Sendable () throws -> Set<String>,
        importFile: @escaping @Sendable (URL, String) throws -> Void,
        recordingURL: @escaping @Sendable () throws -> URL,
        finishRecording: @escaping @Sendable (URL, String, Date) throws -> Void,
        discardRecording: @escaping @Sendable (URL) -> Void
    ) {
        self.root = root
        self.names = names
        self.importFile = importFile
        self.recordingURL = recordingURL
        self.finishRecording = finishRecording
        self.discardRecording = discardRecording
    }
}

public func fileInbox(root: URL) -> Inbox {
    let staging = root.appending(path: ".entrando")
    let prepare: @Sendable () throws -> Void = {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }
    let settle: @Sendable (URL, String) throws -> Void = { temporary, name in
        try FileManager.default.moveItem(at: temporary, to: root.appending(path: name))
    }
    return Inbox(
        root: root,
        names: {
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
            return Set(
                try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).map(\.lastPathComponent))
        },
        importFile: { source, name in
            try prepare()
            let temporary = staging.appending(path: "\(UUID().uuidString)-\(name)")
            try FileManager.default.copyItem(at: source, to: temporary)
            try settle(temporary, name)
        },
        recordingURL: {
            try prepare()
            return staging.appending(path: "\(UUID().uuidString).m4a")
        },
        finishRecording: { temporary, name, startedAt in
            try FileManager.default.setAttributes(
                [.modificationDate: startedAt], ofItemAtPath: temporary.path(percentEncoded: false))
            try settle(temporary, name)
        },
        discardRecording: { temporary in
            try? FileManager.default.removeItem(at: temporary)
        })
}
