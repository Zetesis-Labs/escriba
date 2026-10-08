import Foundation
import EscribaCore

public struct RecordingSource: Sendable {
    public let name: String
    public let locations: [URL]
    public let expectedSpeakers: Int?
    public let chosenRecipe: @Sendable (Recording) throws -> String?
    public let scan: @Sendable () throws -> [Recording]

    public init(
        name: String,
        locations: [URL],
        expectedSpeakers: Int? = nil,
        chosenRecipe: @escaping @Sendable (Recording) throws -> String? = { _ in nil },
        scan: @escaping @Sendable () throws -> [Recording]
    ) {
        self.name = name
        self.locations = locations
        self.expectedSpeakers = expectedSpeakers
        self.chosenRecipe = chosenRecipe
        self.scan = scan
    }
}

public func namespaced(_ source: RecordingSource, prefix: String) -> RecordingSource {
    RecordingSource(
        name: source.name,
        locations: source.locations,
        expectedSpeakers: source.expectedSpeakers,
        chosenRecipe: source.chosenRecipe,
        scan: {
            try source.scan().map { recording in
                Recording(
                    url: recording.url,
                    startedAt: recording.startedAt,
                    key: "\(prefix)/\(recording.key)")
            }
        })
}
