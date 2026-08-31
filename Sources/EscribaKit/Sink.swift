import Foundation
import EscribaCore

public typealias Sink = @Sendable (Recording, Transcript) throws -> URL

public func sidecarTextSink(outputRoot: URL) -> Sink {
    { recording, transcript in
        let target = outputRoot.appending(path: "\(recording.key).txt")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (transcript.rendered + "\n").write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}

public func sinks(primary: @escaping Sink, also secondaries: Sink...) -> Sink {
    { recording, transcript in
        let output = try primary(recording, transcript)
        for sink in secondaries { _ = try sink(recording, transcript) }
        return output
    }
}
