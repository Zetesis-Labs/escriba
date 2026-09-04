import Foundation

public struct DirectoryEntry: Sendable, Equatable {
    public let url: URL
    public let fileIdentifier: UInt64?
    public let modifiedAt: Date

    public init(url: URL, fileIdentifier: UInt64?, modifiedAt: Date) {
        self.url = url
        self.fileIdentifier = fileIdentifier
        self.modifiedAt = modifiedAt
    }
}

public func voiceMemoRecordings(_ entries: [DirectoryEntry], root: URL) -> [Recording] {
    entries
        .compactMap { entry in
            guard let relative = recordingKey(for: entry.url, root: root),
                  !relative.contains("/")
            else { return nil }

            return Recording(
                url: entry.url,
                startedAt: entry.modifiedAt,
                key: entry.fileIdentifier.map(String.init) ?? relative)
        }
        .sorted { $0.startedAt < $1.startedAt }
}
