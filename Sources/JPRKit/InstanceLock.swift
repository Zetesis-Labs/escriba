import Foundation

public struct InstanceLock: ~Copyable, Sendable {
    private let descriptor: Int32

    public init?(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = open(path.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }

        descriptor = fd

        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func holderDescription(path: URL) -> String {
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return "otra instancia" }
        return "otra instancia (pid \(pid))"
    }
}
