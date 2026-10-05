import Foundation
import Synchronization
import EscribaCore
import EscribaEngine

public struct OKFFolder: Sendable {
    public let root: URL
    public var read: @Sendable (String) throws -> String?
    public var list: @Sendable (String) throws -> [String]
    public var write: @Sendable (String, String) throws -> Void
    public var remove: @Sendable (String) throws -> Void

    public init(
        root: URL,
        read: @escaping @Sendable (String) throws -> String?,
        list: @escaping @Sendable (String) throws -> [String],
        write: @escaping @Sendable (String, String) throws -> Void,
        remove: @escaping @Sendable (String) throws -> Void
    ) {
        self.root = root
        self.read = read
        self.list = list
        self.write = write
        self.remove = remove
    }
}

public func fileFolder(_ root: URL) -> OKFFolder {
    let url: @Sendable (String) -> URL = { root.appending(path: $0) }
    let exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    return OKFFolder(
        root: root,
        read: { path in
            let target = url(path)
            guard exists(target) else { return nil }
            return try String(contentsOf: target, encoding: .utf8)
        },
        list: { folder in
            let target = url(folder)
            guard exists(target) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false))
                .filter { $0.hasSuffix(".md") }
        },
        write: { path, contents in
            let target = url(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
        },
        remove: { path in
            let target = url(path)
            guard exists(target) else { return }
            try FileManager.default.removeItem(at: target)
        })
}

public struct OKFJournal: Sendable {
    public var known: @Sendable (String) throws -> String?
    public var published: @Sendable (String, String, Date) -> Void
    public var failed: @Sendable (String, String) -> Void

    public init(
        known: @escaping @Sendable (String) throws -> String? = { _ in nil },
        published: @escaping @Sendable (String, String, Date) -> Void,
        failed: @escaping @Sendable (String, String) -> Void
    ) {
        self.known = known
        self.published = published
        self.failed = failed
    }

    public static let silent = OKFJournal(published: { _, _, _ in }, failed: { _, _ in })
}

private let bundleWrites = Mutex(())

public func okfSink(
    export: OKFExport,
    folder: OKFFolder,
    journal: OKFJournal = .silent,
    producer: String,
    timeZone: TimeZone = .current,
    now: @escaping @Sendable () -> Date = Date.init
) -> Sink {
    { note in
        let key = note.recording.key
        do {
            let known = try journal.known(key)
            let moment = now()
            let notePath = try bundleWrites.withLock { _ in
                let publication = okfPublication(
                    note, as: export, in: try readBundle(folder), known: known,
                    producer: producer, now: moment, timeZone: timeZone)
                try apply(publication.changes, to: folder)
                return publication.notePath
            }
            journal.published(key, notePath, moment)
            Log.info("\(key) escrito en el bundle OKF")
            return folder.root.appending(path: notePath)
        } catch {
            journal.failed(key, error.localizedDescription)
            Log.error("\(key) no se escribio en el bundle OKF: \(error)")
            throw error
        }
    }
}

public func okfUnpublish(
    _ notePath: String, from folder: OKFFolder, timeZone: TimeZone = .current,
    now: @Sendable () -> Date = Date.init
) throws {
    let moment = now()
    try bundleWrites.withLock { _ in
        try apply(okfRemoval(of: notePath, in: try readBundle(folder), now: moment, timeZone: timeZone), to: folder)
    }
}

func readBundle(_ folder: OKFFolder) throws -> BundleState {
    var files: [String: String] = [:]
    for subfolder in [okfNotesFolder, okfTranscriptsFolder] {
        for name in try folder.list(subfolder) {
            let path = "\(subfolder)/\(name)"
            files[path] = try folder.read(path)
        }
    }
    files["log.md"] = try folder.read("log.md")
    return bundleState(from: files)
}

func apply(_ changes: [FileChange], to folder: OKFFolder) throws {
    for change in changes {
        switch change {
        case .write(let path, let contents): try folder.write(path, contents)
        case .remove(let path): try folder.remove(path)
        }
    }
}
