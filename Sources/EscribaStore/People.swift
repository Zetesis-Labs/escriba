import Foundation
import GRDB
import EscribaCore

public struct Person: Sendable, Equatable, Identifiable {
    public let name: String
    public let voices: [PersonVoice]

    public var id: String { name }
}

public struct PersonVoice: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let model: String
    public let source: String
    public let addedAt: Date
}

extension Store {
    public func people() throws -> [Person] {
        try writer.read { db in
            let voices = Dictionary(grouping: try PersonVoiceRow.order(PersonVoiceRow.Columns.id).fetchAll(db), by: \.personId)
            return try PersonRow.order(PersonRow.Columns.name).fetchAll(db).compactMap { row in
                guard let id = row.id, let own = voices[id], !own.isEmpty else { return nil }
                return Person(
                    name: row.name,
                    voices: own.compactMap { voice in
                        voice.id.map { PersonVoice(id: $0, model: voice.model, source: voice.source, addedAt: voice.addedAt) }
                    })
            }
        }
    }

    public func knownVoices() throws -> [KnownVoice] {
        try writer.read { db in
            let names = Dictionary(
                uniqueKeysWithValues: try PersonRow.fetchAll(db).compactMap { row in row.id.map { ($0, row.name) } })
            return readable(try PersonVoiceRow.order(PersonVoiceRow.Columns.id).fetchAll(db).compactMap { voice in
                names[voice.personId].map { person in
                    (decodedEmbedding(voice.embedding).map { KnownVoice(person: person, embedding: $0, model: voice.model) }, person)
                }
            })
        }
    }

    public func addVoices(_ voices: [SpeakerVoice], to person: String, source: String) async throws {
        guard !voices.isEmpty else { return }
        try await writer.write { db in try Self.insert(voices, to: person, source: source, in: db) }
    }

    public func addCorrection(
        _ corrected: Transcript, for key: String, digest: Digest?, teaching voices: [SpeakerVoice], to person: String
    ) async throws {
        try await writer.write { db in
            try Self.attach(corrected, to: key, backend: "correccion", options: nil, digest: digest, in: db)
            if !voices.isEmpty { try Self.insert(voices, to: person, source: key, in: db) }
        }
    }

    private static func insert(_ voices: [SpeakerVoice], to person: String, source: String, in db: Database) throws {
        let personId = try personId(person, creating: true, in: db)
        for voice in voices {
            var row = PersonVoiceRow(
                personId: personId, model: voice.model, embedding: encodedEmbedding(voice.embedding),
                source: source, addedAt: Date())
            try row.insert(db)
        }
    }

    public func removeVoice(_ id: Int64) async throws {
        try await writer.write { db in
            _ = try PersonVoiceRow.deleteOne(db, key: id)
            try Self.forgetPeopleWithoutVoices(in: db)
        }
    }

    public func renamePerson(_ name: String, to newName: String) async throws {
        guard name != newName else { return }
        try await writer.write { db in
            let source = try Self.personId(name, creating: false, in: db)
            if let target = try PersonRow.filter(PersonRow.Columns.name == newName).fetchOne(db)?.id {
                try PersonVoiceRow.filter(PersonVoiceRow.Columns.personId == source)
                    .updateAll(db, PersonVoiceRow.Columns.personId.set(to: target))
                _ = try PersonRow.deleteOne(db, key: source)
            } else {
                try PersonRow.filter(PersonRow.Columns.id == source).updateAll(db, PersonRow.Columns.name.set(to: newName))
            }
        }
    }

    public func removePerson(_ name: String) async throws {
        try await writer.write { db in
            _ = try PersonRow.filter(PersonRow.Columns.name == name).deleteAll(db)
        }
    }

    private static func personId(_ name: String, creating: Bool, in db: Database) throws -> Int64 {
        if let id = try PersonRow.filter(PersonRow.Columns.name == name).fetchOne(db)?.id { return id }
        guard creating else { throw StoreError.unknownPerson(name) }
        var row = PersonRow(name: name, createdAt: Date())
        try row.insert(db)
        guard let id = row.id else { throw StoreError.missingRowID }
        return id
    }

    private static func forgetPeopleWithoutVoices(in db: Database) throws {
        try db.execute(sql: "DELETE FROM person WHERE id NOT IN (SELECT personId FROM personVoice)")
    }
}
