import Foundation
import EscribaCore

public actor ConnectorArchive {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func retain(_ program: ConnectorProgram) throws {
        let url = try location("packages", key: program.fingerprint)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try JSONDecoder().decode(ConnectorProgram.self, from: Data(contentsOf: url))
            guard existing == program else { throw ConnectorHostError.conflict }
            return
        }
        try JSONEncoder().encode(program).write(to: url, options: .atomic)
    }

    public func program(fingerprint: String) throws -> ConnectorProgram {
        try JSONDecoder().decode(ConnectorProgram.self, from: Data(contentsOf: location("packages", key: fingerprint)))
    }

    public func save(recording: String, destination: String, record: ConnectorPublicationRecord) throws {
        _ = try program(fingerprint: record.programFingerprint)
        try JSONEncoder().encode(record).write(to: location("publications", key: key(recording, destination)), options: .atomic)
    }

    public func load(recording: String, destination: String) throws -> ConnectorPublicationRecord? {
        let url = try location("publications", key: key(recording, destination))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ConnectorPublicationRecord.self, from: Data(contentsOf: url))
    }

    private func key(_ recording: String, _ destination: String) -> String {
        "\(recording.utf8.count):\(recording)\(destination)"
    }

    private func location(_ section: String, key: String) throws -> URL {
        let folder = directory.appending(path: section)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoded = connectorFingerprint(key)
        return folder.appending(path: encoded + ".json")
    }
}
