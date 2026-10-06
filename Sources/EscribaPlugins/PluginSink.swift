import Foundation
import EscribaCore
import EscribaEngine
import EscribaPluginKit

public struct PluginJournal: Sendable {
    public var known: @Sendable (String) throws -> PluginRef?
    public var published: @Sendable (String, PluginRef, Date) -> Void
    public var failed: @Sendable (String, String) -> Void

    public init(
        known: @escaping @Sendable (String) throws -> PluginRef? = { _ in nil },
        published: @escaping @Sendable (String, PluginRef, Date) -> Void,
        failed: @escaping @Sendable (String, String) -> Void
    ) {
        self.known = known
        self.published = published
        self.failed = failed
    }

    public static let silent = PluginJournal(published: { _, _, _ in }, failed: { _, _ in })
}

public struct PluginBinding: Sendable {
    public let module: PluginModule
    public let manifest: PluginManifest
    public let config: PluginJSON
    public let secrets: [String: String]

    public init(module: PluginModule, manifest: PluginManifest, config: PluginJSON, secrets: [String: String]) {
        self.module = module
        self.manifest = manifest
        self.config = config
        self.secrets = secrets
    }

    public var permissions: PluginPermissions {
        PluginPermissions(
            hosts: manifest.hosts,
            folder: manifest.folder.flatMap { field in
                let path = config.text(field)
                return path.isEmpty ? nil : URL(fileURLWithPath: path)
            },
            secrets: secrets)
    }

    public var markedConfig: PluginJSON {
        withSecretMarkers(config, present: secrets.keys.filter { !(secrets[$0] ?? "").isEmpty })
    }

    public func run(_ request: PluginRequest) async throws -> PluginResponse {
        var request = request
        request.config = markedConfig
        let outcome = try await module.run(request, permissions: permissions)
        if let error = outcome.response.error { throw HostError(error) }
        return outcome.response
    }
}

public func pluginSink(
    _ binding: PluginBinding, journal: PluginJournal = .silent, now: @escaping @Sendable () -> Date = Date.init
) -> Sink {
    { note in
        do {
            let response = try await binding.run(PluginRequest(
                command: .publish, note: PluginNote(note), known: try journal.known(note.recording.key)))
            guard let ref = response.ref else { throw HostError("el plugin no devolvió ninguna referencia") }
            journal.published(note.recording.key, ref, now())
            Log.info("plugin \(binding.manifest.name) publicó \(note.recording.key)")
            return URL(string: ref.url ?? "") ?? note.recording.url
        } catch {
            journal.failed(note.recording.key, "\(error)")
            Log.error("\(note.recording.key) no se publicó con \(binding.manifest.name): \(error)")
            throw error
        }
    }
}

public func pluginUnpublisher(_ binding: PluginBinding) -> @Sendable (String) async throws -> Void {
    { ref in _ = try await binding.run(PluginRequest(command: .unpublish, ref: ref)) }
}
