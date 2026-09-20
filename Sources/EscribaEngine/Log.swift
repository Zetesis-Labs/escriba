import Foundation
import Synchronization

public enum Log {
    nonisolated(unsafe) public static var verbose = false
    private static let fileHandle = Mutex<FileHandle?>(nil)

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func mirrorToFile(_ url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
            manager.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        fileHandle.withLock { $0 = handle }
    }

    public static func info(_ message: String) { emit("INFO ", message) }
    public static func error(_ message: String) { emit("ERROR", message) }
    public static func debug(_ message: String) {
        if verbose { emit("DEBUG", message) }
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level)  \(message)"
        let data = Data((line + "\n").utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)

        fileHandle.withLock { handle in
            try? handle?.write(contentsOf: data)
        }
    }
}
