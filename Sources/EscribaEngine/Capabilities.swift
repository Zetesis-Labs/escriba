import Foundation
import EscribaCore

struct Take: Sendable {
    let transcript: Transcript
    let version: Int64?
    let digest: Digest?

    func carrying(_ digest: Digest) -> Take {
        Take(transcript: transcript, version: version, digest: digest)
    }
}

struct Capabilities: Sendable {
    let backend: TranscriptionBackend
    let enrich: Enricher?
    let memory: NoteMemory?

    func transcribe(_ recording: Recording, with chosen: TranscriptionBackend? = nil) async throws -> Take {
        let backend = chosen ?? backend
        let inputs = backend.inputs(recording.url)
        if let remembered = try await memory?.recall(recording, inputs) {
            Log.info("\(recording.key) ya estaba transcrita, se recupera de la biblioteca")
            return Take(
                transcript: remembered.transcript, version: remembered.version, digest: remembered.digest)
        }
        let transcript = try await backend.transcribe(recording.url)
        let version = try await memory?.keepTranscript(recording, transcript, inputs)
        return Take(transcript: transcript, version: version, digest: nil)
    }

    func summarize(_ recording: Recording, _ take: Take, with chosen: Enricher? = nil) async throws -> Take {
        guard take.digest == nil, let enrich = chosen ?? enrich,
            let digest = await enrich(recording, take.transcript)
        else {
            return take
        }
        if let version = take.version {
            try await memory?.keepDigest(recording, version, digest)
        }
        return take.carrying(digest)
    }
}
