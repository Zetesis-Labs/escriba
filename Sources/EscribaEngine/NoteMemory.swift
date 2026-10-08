import Foundation
import EscribaCore

public struct Remembered: Sendable, Equatable {
    public let version: Int64
    public let transcript: Transcript
    public let digest: Digest?
    public let data: DataValue?

    public init(version: Int64, transcript: Transcript, digest: Digest?, data: DataValue? = nil) {
        self.version = version
        self.transcript = transcript
        self.digest = digest
        self.data = data
    }
}

public struct NoteMemory: Sendable {
    public var recall: @Sendable (Recording, TranscriptionInputs) async throws -> Remembered?
    public var keepTranscript: @Sendable (Recording, Transcript, TranscriptionInputs) async throws -> Int64
    public var keepDigest: @Sendable (_ recording: Recording, _ version: Int64, Digest) async throws -> Void
    public var keepData: @Sendable (_ recording: Recording, _ version: Int64, DataValue?) async throws -> Void
    public var recallAnswer: @Sendable (_ recording: Recording, _ version: Int64, _ fingerprint: String) async throws -> String?
    public var keepAnswer: @Sendable (_ recording: Recording, _ version: Int64, _ fingerprint: String, _ answer: String) async throws -> Void

    public init(
        recall: @escaping @Sendable (Recording, TranscriptionInputs) async throws -> Remembered?,
        keepTranscript: @escaping @Sendable (Recording, Transcript, TranscriptionInputs) async throws -> Int64,
        keepDigest: @escaping @Sendable (Recording, Int64, Digest) async throws -> Void,
        keepData: @escaping @Sendable (Recording, Int64, DataValue?) async throws -> Void = { _, _, _ in },
        recallAnswer: @escaping @Sendable (Recording, Int64, String) async throws -> String? = { _, _, _ in nil },
        keepAnswer: @escaping @Sendable (Recording, Int64, String, String) async throws -> Void = { _, _, _, _ in }
    ) {
        self.recall = recall
        self.keepTranscript = keepTranscript
        self.keepDigest = keepDigest
        self.keepData = keepData
        self.recallAnswer = recallAnswer
        self.keepAnswer = keepAnswer
    }
}
