import Foundation
import EscribaCore

public enum FileSystem {
    public static func probe(_ url: URL) -> Probe? {
        var st = stat()
        guard stat(url.path(percentEncoded: false), &st) == 0 else { return nil }

        return Probe(
            size: Int64(st.st_size),
            blocks: Int64(st.st_blocks),
            flags: st.st_flags,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
            observedAt: Date()
        )
    }

    public static func scan(root: URL) throws -> [Recording] {
        let manager = FileManager.default
        let days: [URL]
        do {
            days = try manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw ScanError.unreadable(root: root.path(percentEncoded: false), underlying: error)
        }

        return days.flatMap { day -> [Recording] in
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let entries = try? manager.contentsOfDirectory(
                    at: day, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { return [] }

            return entries.compactMap { RecordingParser.parse($0, root: root) }
        }
    }

    public static func scanAudio(root: URL) throws -> [Recording] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            throw ScanError.unreadable(
                root: root.path(percentEncoded: false),
                underlying: CocoaError(.fileReadNoSuchFile))
        }

        var recordings: [Recording] = []
        for case let url as URL in walker {
            guard let key = recordingKey(for: url, root: root) else { continue }
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date()
            recordings.append(Recording(url: url, startedAt: modified, key: key))
        }
        return recordings
    }

    public static func scanVoiceMemos(root: URL) throws -> [Recording] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.fileIdentifierKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw ScanError.unreadable(root: root.path(percentEncoded: false), underlying: error)
        }

        return voiceMemoRecordings(entries.map(entry), root: root)
    }

    public static func accessProblem(root: URL) -> ScanError? {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])
            return nil
        } catch {
            return ScanError.unreadable(root: root.path(percentEncoded: false), underlying: error)
        }
    }

    private static func entry(_ url: URL) -> DirectoryEntry {
        let values = try? url.resourceValues(
            forKeys: [.fileIdentifierKey, .contentModificationDateKey])
        return DirectoryEntry(
            url: url,
            fileIdentifier: values?.fileIdentifier,
            modifiedAt: values?.contentModificationDate ?? Date())
    }

    @discardableResult
    public static func requestMaterialization(_ url: URL, timeout: TimeInterval) -> Bool {
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            if let handle = try? FileHandle(forReadingFrom: url) {
                _ = try? handle.read(upToCount: 1)
                try? handle.close()
            }
            finished.signal()
        }

        return finished.wait(timeout: .now() + timeout) == .success
    }
}

public enum ScanError: Error, CustomStringConvertible {
    case unreadable(root: String, underlying: Error)

    public var description: String {
        switch self {
        case .unreadable(let root, let underlying):
            "no se puede leer \(root) — \(underlying.localizedDescription). Comprueba el Acceso total al disco."
        }
    }
}
