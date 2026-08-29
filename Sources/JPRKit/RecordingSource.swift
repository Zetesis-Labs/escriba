import Foundation
import JPRCore

public struct RecordingSource: Sendable {
    public let name: String
    public let locations: [URL]
    public let expectedSpeakers: Int?
    public let scan: @Sendable () throws -> [Recording]

    public init(
        name: String,
        locations: [URL],
        expectedSpeakers: Int? = nil,
        scan: @escaping @Sendable () throws -> [Recording]
    ) {
        self.name = name
        self.locations = locations
        self.expectedSpeakers = expectedSpeakers
        self.scan = scan
    }
}

public func justPressRecordSource(root: URL) -> RecordingSource {
    RecordingSource(
        name: "Just Press Record",
        locations: [root],
        scan: { try FileSystem.scan(root: root) })
}

public func folderSource(
    name: String, root: URL, expectedSpeakers: Int? = nil
) -> RecordingSource {
    RecordingSource(
        name: name,
        locations: [root],
        expectedSpeakers: expectedSpeakers,
        scan: { try FileSystem.scanAudio(root: root) })
}
