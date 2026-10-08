import Foundation
import EscribaCore

public struct Inbox: Sendable {
    public let root: URL
    public var names: @Sendable () throws -> Set<String>
    public var importFile: @Sendable (URL, String, _ recipe: String?) throws -> Void
    public var recordingURL: @Sendable () throws -> URL
    public var finishRecording: @Sendable (URL, String, Date, _ recipe: String?) throws -> Void
    public var discardRecording: @Sendable (URL) -> Void
    public var recipe: @Sendable (URL) throws -> String?

    public init(
        root: URL,
        names: @escaping @Sendable () throws -> Set<String>,
        importFile: @escaping @Sendable (URL, String, String?) throws -> Void,
        recordingURL: @escaping @Sendable () throws -> URL,
        finishRecording: @escaping @Sendable (URL, String, Date, String?) throws -> Void,
        discardRecording: @escaping @Sendable (URL) -> Void,
        recipe: @escaping @Sendable (URL) throws -> String? = { _ in nil }
    ) {
        self.root = root
        self.names = names
        self.importFile = importFile
        self.recordingURL = recordingURL
        self.finishRecording = finishRecording
        self.discardRecording = discardRecording
        self.recipe = recipe
    }
}

public func fileInbox(root: URL) -> Inbox {
    let staging = root.appending(path: ".entrando")
    let prepare: @Sendable () throws -> Void = {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }
    let settle: @Sendable (URL, String, String?) throws -> Void = { temporary, name, recipe in
        let destination = root.appending(path: name)
        let chosen = root.appending(path: inboxRecipeFile(for: name))
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path(percentEncoded: false)])
        }
        if let recipe {
            try Data("\(recipe)\n".utf8).write(to: chosen, options: .atomic)
        } else if FileManager.default.fileExists(atPath: chosen.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: chosen)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            if recipe != nil { try? FileManager.default.removeItem(at: chosen) }
            throw error
        }
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
        importFile: { source, name, recipe in
            try prepare()
            let temporary = staging.appending(path: "\(UUID().uuidString)-\(name)")
            try FileManager.default.copyItem(at: source, to: temporary)
            try settle(temporary, name, recipe)
        },
        recordingURL: {
            try prepare()
            return staging.appending(path: "\(UUID().uuidString).m4a")
        },
        finishRecording: { temporary, name, startedAt, recipe in
            try FileManager.default.setAttributes(
                [.modificationDate: startedAt], ofItemAtPath: temporary.path(percentEncoded: false))
            try settle(temporary, name, recipe)
        },
        discardRecording: { temporary in
            try? FileManager.default.removeItem(at: temporary)
        },
        recipe: { audio in
            let chosen = audio.deletingLastPathComponent().appending(path: inboxRecipeFile(for: audio.lastPathComponent))
            guard FileManager.default.fileExists(atPath: chosen.path(percentEncoded: false)) else { return nil }
            return inboxRecipe(from: try String(contentsOf: chosen, encoding: .utf8))
        })
}
