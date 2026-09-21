import Foundation
import EscribaCore

public typealias Sink = @Sendable (Note) async throws -> URL

public func sidecarTextSink(outputRoot: URL) -> Sink {
    { note in
        try writeSidecarText(outputRoot: outputRoot, key: note.recording.key, transcript: note.transcript)
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
    sinks(primary: primary, all: secondaries)
}

public func sinks(primary: @escaping Sink, all secondaries: [Sink]) -> Sink {
    { note in
        let output = try await primary(note)
        for sink in secondaries { _ = try await sink(note) }
        return output
    }
}

public func forgiving(_ sink: @escaping Sink) -> Sink {
    { note in
        do {
            return try await sink(note)
        } catch {
            Log.error("\(note.recording.key): un destino fallo y se deja para reintentar: \(error)")
            return note.recording.url
        }
    }
}
