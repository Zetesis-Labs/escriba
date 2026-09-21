public struct Note: Sendable, Equatable {
    public let recording: Recording
    public let transcript: Transcript
    public let digest: Digest?

    public init(recording: Recording, transcript: Transcript, digest: Digest? = nil) {
        self.recording = recording
        self.transcript = transcript
        self.digest = digest
    }
}
