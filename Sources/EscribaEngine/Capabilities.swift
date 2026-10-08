import Foundation
import EscribaCore

struct Take: Sendable {
    let transcript: Transcript
    let version: Int64?
    let digest: Digest?
    var data: DataValue? = nil

    func carrying(_ digest: Digest) -> Take {
        Take(transcript: transcript, version: version, digest: digest, data: data)
    }

    func carrying(data: DataValue?) -> Take {
        Take(transcript: transcript, version: version, digest: digest, data: data)
    }
}

struct Capabilities: Sendable {
    let backend: TranscriptionBackend
    let enrich: Enricher?
    let memory: NoteMemory?
    var readOnly = false

    func transcribe(_ recording: Recording, with chosen: TranscriptionBackend? = nil) async throws -> Take {
        let backend = chosen ?? backend
        let inputs = backend.inputs(recording.url)
        if let remembered = try await memory?.recall(recording, inputs) {
            Log.info("\(recording.key) ya estaba transcrita, se recupera de la biblioteca")
            return Take(
                transcript: remembered.transcript, version: remembered.version, digest: remembered.digest,
                data: remembered.data)
        }
        let transcript = try await backend.transcribe(recording.url)
        let version = readOnly ? nil : try await memory?.keepTranscript(recording, transcript, inputs)
        return Take(transcript: transcript, version: version, digest: nil)
    }

    func summarize(_ recording: Recording, _ take: Take, with chosen: Enricher? = nil) async throws -> Take {
        guard take.digest == nil, let enrich = chosen ?? enrich,
            let digest = await enrich(recording, take.transcript)
        else {
            return take
        }
        if !readOnly, let version = take.version {
            try await memory?.keepDigest(recording, version, digest)
        }
        return take.carrying(digest)
    }

    func ask(
        _ recording: Recording, version: Int64?, asker: Asker, request: AnswerRequest, fingerprint: String
    ) async throws -> (answer: DataValue, remembered: Bool) {
        if let version, let kept = try await memory?.recallAnswer(recording, version, fingerprint),
            let answer = try? parseData(kept)
        {
            return (answer, true)
        }
        let answer = try await asker.answer(request)
        if !readOnly, let version {
            try await memory?.keepAnswer(recording, version, fingerprint, dataText(answer))
        }
        return (answer, false)
    }

    func keep(_ data: DataValue?, of recording: Recording, in take: Take) async throws {
        guard !readOnly, data != take.data, let version = take.version else { return }
        try await memory?.keepData(recording, version, data)
    }
}
