import Foundation
import JPRCore

public typealias Sink = @Sendable (Recording, String) throws -> URL

public func sidecarTextSink(outputRoot: URL) -> Sink {
    { recording, text in
        let target = outputRoot.appending(path: "\(recording.key).txt")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
