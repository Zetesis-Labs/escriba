import Foundation
import EscribaCore
import EscribaEngine
import EscribaStore
import EscribaSystemKit

nonisolated public struct ConnectorPermission: Codable, Sendable, Equatable {
    public var account: String
    public var capability: String
    public var origin: String?
    public var folder: String?
    public var enabled: Bool
    public var allowedHeaders: [String]

    public init(account: String, capability: String, origin: String? = nil, folder: String? = nil, enabled: Bool, allowedHeaders: [String] = ["content-type", "accept"]) {
        self.account = account
        self.capability = capability
        self.origin = origin
        self.folder = folder
        self.enabled = enabled
        self.allowedHeaders = allowedHeaders
    }
}

nonisolated public struct ConnectorBinding: Codable, Sendable {
    public var key: String
    public var provider: String
    public var destination: String?
    public var configurationJSON: String
    public var programFingerprint: String
    public var permission: ConnectorPermission
    public var allowsNewPublications: Bool

    public init(key: String, provider: String, destination: String? = nil, configurationJSON: String,
                programFingerprint: String, permission: ConnectorPermission, allowsNewPublications: Bool = true) {
        self.key = key
        self.provider = provider
        self.destination = destination
        self.configurationJSON = configurationJSON
        self.programFingerprint = programFingerprint
        self.permission = permission
        self.allowsNewPublications = allowsNewPublications
    }
}

public enum ConnectorPublicationError: Error, LocalizedError {
    case invalidResult, uncertain, unavailable, journal(String, String)
    nonisolated public var errorDescription: String? {
        switch self {
        case .invalidResult: "El conector no devolvió un localizador y un recibo válidos."
        case .uncertain: "La publicación quedó interrumpida sin recibo. Hay que reconciliar el destino antes de crear otra."
        case .unavailable: "El destino ya no está disponible para nuevas publicaciones."
        case .journal(let original, let persistence): "\(original). Además, no se pudo guardar el fallo: \(persistence)"
        }
    }
}

public actor ConnectorPublications {
    private let store: Store
    private let archive: ConnectorArchive
    private let runtime: ConnectorRuntime
    private let authority: @Sendable (String) async -> ConnectorPermission?
    private let credentials: @Sendable (String) -> String?
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(store: Store, archive: ConnectorArchive, runtime: ConnectorRuntime,
                authority: @escaping @Sendable (String) async -> ConnectorPermission?,
                credentials: @escaping @Sendable (String) -> String?) {
        self.store = store
        self.archive = archive
        self.runtime = runtime
        self.authority = authority
        self.credentials = credentials
    }

    public func publish(_ note: Note, to binding: ConnectorBinding) async throws -> URL? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        do {
            return try await perform("publish", key: note.recording.key, binding: binding, note: note, locator: nil)
        } catch {
            do { try store.markPublishFailed(key: note.recording.key, connector: binding.key, error: error.localizedDescription) }
            catch let persistence { throw ConnectorPublicationError.journal(error.localizedDescription, persistence.localizedDescription) }
            throw error
        }
    }

    public func remove(key: String, locator: String, from binding: ConnectorBinding) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        _ = try await perform("remove", key: key, binding: binding, note: nil, locator: locator)
    }

    private func perform(_ operation: String, key: String, binding current: ConnectorBinding,
                         note: Note?, locator: String?) async throws -> URL? {
        let saved = try await archive.load(recording: key, destination: current.key)
        let reusable = saved.map { $0.state != "removed" && !($0.state == "prepared" && $0.receiptJSON == nil && $0.locator == nil) } ?? false
        let previous = reusable ? saved : nil
        let binding = try previous.map { try JSONDecoder().decode(ConnectorBinding.self, from: Data($0.configJSON.utf8)) } ?? current
        try await authorize(binding.permission)
        let legacy = saved == nil ? try store.recording(for: key)?.publication(in: current.key) : nil
        if operation == "publish", previous == nil, legacy?.pageId == nil, !current.allowsNewPublications {
            throw ConnectorPublicationError.unavailable
        }
        if let previous, previous.receiptJSON == nil, previous.locator == nil, previous.state == "running" {
            throw ConnectorPublicationError.uncertain
        }
        let program = try await archive.program(fingerprint: binding.programFingerprint)
        var record = try previous ?? ConnectorPublicationRecord(
            programFingerprint: program.fingerprint,
            configJSON: String(decoding: try JSONEncoder().encode(binding), as: UTF8.self),
            state: "prepared", locator: locator ?? legacy?.pageId, url: legacy?.url?.absoluteString)
        let request = try requestJSON(operation: operation, binding: binding, note: note, record: record)
        record.state = "prepared"
        try await archive.save(recording: key, destination: current.key, record: record)
        let permission = binding.permission
        let bridge = makeConnectorBridge(grant: ConnectorGrant(
            httpOrigin: permission.capability == "http" ? permission.origin : nil,
            folder: permission.capability == "folder" ? permission.folder.map { URL(fileURLWithPath: $0) } : nil,
            audio: note?.recording.url,
            allowedHeaders: Set(permission.allowedHeaders),
            secret: { [credentials] in
                guard permission.capability == "http" else { return nil }
                guard let token = credentials(permission.account), !token.isEmpty else { throw ConnectorHostError.denied }
                return token
            },
            checkpoint: { [weak self] receipt in
                guard let self else { throw CancellationError() }
                try await self.checkpoint(receipt, recording: key, destination: current.key)
            }))
        let checked = ConnectorBridge { [authority, weak self] request in
            guard let live = await authority(permission.account), live == permission, live.enabled else { throw ConnectorHostError.denied }
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try await self.beforeEffect(request, recording: key, destination: current.key)
            return try await bridge.call(request)
        }
        let result = try await runtime.execute(program, request, checked)
        guard let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              let receipt = object["receipt"], JSONSerialization.isValidJSONObject(receipt) else {
            throw ConnectorPublicationError.invalidResult
        }
        try await checkpoint(Self.json(receipt), recording: key, destination: current.key)
        guard var finished = try await archive.load(recording: key, destination: current.key) else { throw ConnectorPublicationError.invalidResult }
        if operation == "remove" {
            finished.state = "removed"
            try await archive.save(recording: key, destination: current.key, record: finished)
            return nil
        }
        guard let finalLocator = object["locator"] as? String, !finalLocator.isEmpty else { throw ConnectorPublicationError.invalidResult }
        let finalURL: URL?
        if let raw = object["url"] as? String { finalURL = URL(string: raw) }
        else if permission.capability == "folder", let folder = permission.folder, validConnectorRelativePath(finalLocator) {
            finalURL = URL(fileURLWithPath: folder).appending(path: finalLocator)
        } else { finalURL = nil }
        finished.state = "published"
        finished.locator = finalLocator
        finished.url = finalURL?.absoluteString
        try await archive.save(recording: key, destination: current.key, record: finished)
        try store.markPublished(key: key, connector: current.key, pageId: finalLocator, url: finalURL, at: .now)
        return finalURL
    }

    private func beforeEffect(_ request: String, recording: String, destination: String) async throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              let operation = object["op"] as? String else { throw ConnectorHostError.invalidRequest }
        guard operation == "http" || operation == "files.apply" else { return }
        guard var record = try await archive.load(recording: recording, destination: destination) else {
            throw ConnectorPublicationError.invalidResult
        }
        record.state = "running"
        try await archive.save(recording: recording, destination: destination, record: record)
    }

    private func authorize(_ permission: ConnectorPermission) async throws {
        guard let live = await authority(permission.account), live == permission, live.enabled else { throw ConnectorHostError.denied }
    }

    private func checkpoint(_ receipt: String, recording: String, destination: String) async throws {
        guard var record = try await archive.load(recording: recording, destination: destination),
              let object = try JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any] else {
            throw ConnectorPublicationError.invalidResult
        }
        record.receiptJSON = receipt
        if let locator = object["locator"] as? String, !locator.isEmpty { record.locator = locator }
        if let url = object["url"] as? String { record.url = url }
        try await archive.save(recording: recording, destination: destination, record: record)
    }

    private func requestJSON(operation: String, binding: ConnectorBinding, note: Note?, record: ConnectorPublicationRecord) throws -> String {
        var object: [String: Any] = ["operation": operation, "provider": binding.provider,
            "config": try JSONSerialization.jsonObject(with: Data(binding.configurationJSON.utf8)),
            "now": Date().ISO8601Format()]
        if let destination = binding.destination { object["destination"] = destination }
        if let receipt = record.receiptJSON { object["previous"] = try JSONSerialization.jsonObject(with: Data(receipt.utf8)) }
        else if let locator = record.locator {
            var previous: [String: Any] = ["locator": locator]
            if let url = record.url { previous["url"] = url }
            object["previous"] = previous
        }
        if let note {
            var input: [String: Any] = ["key": note.recording.key, "startedAt": note.recording.startedAt.ISO8601Format(),
                "source": "urn:escriba:recording:" + connectorFingerprint(note.recording.key), "text": note.transcript.text,
                "timeZone": TimeZone.current.identifier,
                "segments": try JSONSerialization.jsonObject(with: JSONEncoder().encode(note.transcript.segments))]
            if let digest = note.digest { input["digest"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(digest)) }
            object["note"] = input
        }
        return try Self.json(object)
    }

    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    private func acquire() async {
        if occupied { await withCheckedContinuation { waiting.append($0) } }
        else { occupied = true }
    }

    private func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().resume() }
    }
}
