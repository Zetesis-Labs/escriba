import Foundation
import Synchronization
import EscribaCore
import EscribaEngine

public struct OKFFolder: Sendable {
    public let root: URL
    public var read: @Sendable (String) throws -> String?
    public var list: @Sendable () throws -> [String]
    public var write: @Sendable (String, String) throws -> Void
    public var remove: @Sendable (String) throws -> Void

    public init(
        root: URL,
        read: @escaping @Sendable (String) throws -> String?,
        list: @escaping @Sendable () throws -> [String],
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
        list: { try markdownFiles(under: root) },
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
    public var published: @Sendable (String, String, Date) -> Void
    public var failed: @Sendable (String, String) -> Void

    public init(
        published: @escaping @Sendable (String, String, Date) -> Void,
        failed: @escaping @Sendable (String, String) -> Void
    ) {
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
            guard !export.documents.isEmpty else { throw OKFError.noDocuments }
            let moment = now()
            let notePath = try bundleWrites.withLock { _ in
                let publication = okfPublication(
                    note, as: export, in: try readBundle(folder),
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

public enum OKFError: Error, LocalizedError {
    case noDocuments

    public var errorDescription: String? {
        switch self {
        case .noDocuments: "El conector no tiene ningún documento que escribir."
        }
    }
}

public func okfUnpublish(
    _ notePath: String, from folder: OKFFolder, documents: [OKFDocument] = [], timeZone: TimeZone = .current,
    now: @Sendable () -> Date = Date.init
) throws {
    let moment = now()
    try bundleWrites.withLock { _ in
        let changes = okfRemoval(
            of: notePath, in: try readBundle(folder), documents: documents, now: moment, timeZone: timeZone)
        try apply(changes, to: folder)
    }
}

func readBundle(_ folder: OKFFolder) throws -> BundleState {
    var files: [String: String] = [:]
    for path in try folder.list() where isConcept(path) {
        files[path] = try folder.read(path)
    }
    files["log.md"] = try folder.read("log.md")
    return bundleState(from: files)
}

private func markdownFiles(under root: URL) throws -> [String] {
    var found: [String] = []
    var pending = [""]
    while let folder = pending.popLast() {
        let url = folder.isEmpty ? root : root.appending(path: folder)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        let children = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for child in children {
            let relative = folder.isEmpty ? child.lastPathComponent : "\(folder)/\(child.lastPathComponent)"
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                pending.append(relative)
            } else if child.pathExtension.lowercased() == "md" {
                found.append(relative)
            }
        }
    }
    return found
}

func apply(_ changes: [FileChange], to folder: OKFFolder) throws {
    for change in changes {
        switch change {
        case .write(let path, let contents): try folder.write(path, contents)
        case .remove(let path): try folder.remove(path)
        }
    }
}
