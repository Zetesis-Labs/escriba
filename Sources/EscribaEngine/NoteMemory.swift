import Foundation
import EscribaCore

public struct Remembered: Sendable, Equatable {
    public let version: Int64
    public let transcript: Transcript
    public let digest: Digest?

    public init(version: Int64, transcript: Transcript, digest: Digest?) {
        self.version = version
        self.transcript = transcript
        self.digest = digest
    }
}

public struct NoteMemory: Sendable {
    public var recall: @Sendable (Recording, TranscriptionInputs) async throws -> Remembered?
    public var keepTranscript: @Sendable (Recording, Transcript, TranscriptionInputs) async throws -> Int64
    public var keepDigest: @Sendable (_ recording: Recording, _ version: Int64, Digest) async throws -> Void

    public init(
        recall: @escaping @Sendable (Recording, TranscriptionInputs) async throws -> Remembered?,
        keepTranscript: @escaping @Sendable (Recording, Transcript, TranscriptionInputs) async throws -> Int64,
        keepDigest: @escaping @Sendable (Recording, Int64, Digest) async throws -> Void
    ) {
        self.recall = recall
        self.keepTranscript = keepTranscript
        self.keepDigest = keepDigest
    }
}
