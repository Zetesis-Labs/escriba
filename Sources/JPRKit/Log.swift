import Foundation

public enum Log {
    nonisolated(unsafe) public static var verbose = false
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    private static let lock = NSLock()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func mirrorToFile(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }

        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
            manager.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        fileHandle = handle
    }

    public static func info(_ message: String) { emit("INFO ", message) }
    public static func error(_ message: String) { emit("ERROR", message) }
    public static func debug(_ message: String) {
        if verbose { emit("DEBUG", message) }
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level)  \(message)"
        print(line)
        fflush(stdout)

        lock.lock()
        defer { lock.unlock() }
        if let fileHandle, let data = (line + "\n").data(using: .utf8) {
            try? fileHandle.write(contentsOf: data)
        }
    }
}
