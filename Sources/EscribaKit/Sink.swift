import Foundation
import EscribaCore

public typealias Sink = @Sendable (Recording, Transcript) throws -> URL

public func sidecarTextSink(outputRoot: URL) -> Sink {
    { recording, transcript in
        try writeSidecarText(outputRoot: outputRoot, key: recording.key, transcript: transcript)
    }
}

@discardableResult
public func writeSidecarText(
    outputRoot: URL, key: String, transcript: Transcript
) throws -> URL {
    let target = sidecarTextURL(outputRoot: outputRoot, key: key)
    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (transcript.rendered + "\n").write(to: target, atomically: true, encoding: .utf8)
    return target
}

public func sinks(primary: @escaping Sink, also secondaries: Sink...) -> Sink {
    { recording, transcript in
        let output = try primary(recording, transcript)
        for sink in secondaries { _ = try sink(recording, transcript) }
        return output
    }
}
