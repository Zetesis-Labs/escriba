import Foundation
import EscribaCore
import EscribaKit

extension Store {
    public static let importedBackend = "importado"

    @discardableResult
    public func adoptLedgerHistory(_ records: [LedgerRecord]) -> Int {
        var adopted = 0
        for record in records {
            do {
                if try adopt(record) { adopted += 1 }
            } catch {
                Log.error("no se pudo importar \(record.key) a la biblioteca: \(error)")
            }
        }
        if adopted > 0 {
            Log.info("importadas \(adopted) transcripciones del ledger a la biblioteca")
        }
        return adopted
    }

    private func adopt(_ record: LedgerRecord) throws -> Bool {
        guard try transcriptCount(for: record.key) == 0, let outputPath = record.outputPath
        else { return false }
        guard let raw = try? String(contentsOfFile: outputPath, encoding: .utf8) else {
            return false
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let source = URL(fileURLWithPath: record.sourcePath)
        let startedAt = RecordingParser.startDate(fromKey: record.key)
            ?? FileSystem.probe(source)?.modifiedAt
            ?? Date()
        let recording = Recording(url: source, startedAt: startedAt, key: record.key)
        let transcript = Transcript(text: text)

        if FileManager.default.fileExists(atPath: record.sourcePath) {
            try save(recording, transcript, backend: Self.importedBackend)
        } else if try knows(record.key) {
            try addTranscript(transcript, for: record.key, backend: Self.importedBackend)
        } else {
            try insertDoneWithoutAudio(recording, transcript, backend: Self.importedBackend)
        }
        return true
    }
}
