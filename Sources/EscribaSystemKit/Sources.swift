import Foundation
import EscribaCore
import EscribaEngine

public func justPressRecordSource(root: URL) -> RecordingSource {
    RecordingSource(
        name: "Just Press Record",
        locations: [root],
        scan: { try FileSystem.scan(root: root) })
}

public func folderSource(
    name: String, root: URL, expectedSpeakers: Int? = nil,
    chosenRecipe: @escaping @Sendable (URL) throws -> String? = { _ in nil }
) -> RecordingSource {
    RecordingSource(
        name: name,
        locations: [root],
        expectedSpeakers: expectedSpeakers,
        chosenRecipe: { try chosenRecipe($0.url) },
        scan: { try FileSystem.scanAudio(root: root) })
}

public func voiceMemosSource(root: URL, expectedSpeakers: Int? = nil) -> RecordingSource {
    RecordingSource(
        name: "Notas de Voz",
        locations: [root],
        expectedSpeakers: expectedSpeakers,
        scan: { try FileSystem.scanVoiceMemos(root: root) })
}
