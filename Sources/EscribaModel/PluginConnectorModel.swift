import Foundation
import Observation
import EscribaPluginKit
import EscribaPlugins

public typealias PluginRunner = @Sendable (PluginRequest, [String: String]) async throws -> PluginResponse

@Observable
public final class PluginConnectorModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case working
        case failed(String)

        public var isWorking: Bool { self == .working }

        public var problem: String? {
            guard case .failed(let message) = self else { return nil }
            return message
        }
    }

    public let id: UUID
    public let manifest: PluginManifest
    public private(set) var draft: Connector?
    public private(set) var config: PluginJSON
    public private(set) var form: PluginForm?
    public private(set) var previews: [String: String] = [:]
    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var previewing: Task<Void, Never>?
    public var secrets: [String: String]
    @ObservationIgnored private var savedSecrets: [String: String]
    @ObservationIgnored private var state: PluginJSON = .object([:])
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let stores: [String: TokenStore]
    @ObservationIgnored private let runner: PluginRunner

    public init(
        connector id: UUID, manifest: PluginManifest, settings: AppSettings,
        stores: [String: TokenStore]? = nil, runner: @escaping PluginRunner
    ) {
        self.id = id
        self.manifest = manifest
        self.settings = settings
        self.runner = runner
        let stores = stores ?? Dictionary(uniqueKeysWithValues: manifest.secrets.map { ($0, pluginSecretStore(connector: id, field: $0)) })
        self.stores = stores
        savedSecrets = stores.compactMapValues { $0.read() }
        secrets = savedSecrets
        draft = settings.connector(id)
        config = settings.connector(id)?.plugin?.config ?? .object([:])
        load(immediately: true)
    }

    public var connector: Connector? { settings.connector(id) }

    public var isDirty: Bool {
        draft != connector || config != (connector?.plugin?.config ?? .object([:])) || secrets != savedSecrets
    }

    public var name: String {
        get { draft?.name ?? "" }
        set { edit { $0.name = newValue } }
    }

    public var publishes: Bool {
        get { draft?.enabled ?? false }
        set { edit { $0.enabled = newValue } }
    }

    public var readiness: String? {
        form?.problem ?? "Cargando el plugin…"
    }

    public func value(_ path: String) -> String {
        config.text(path)
    }

    public func setValue(_ value: String, at path: String) {
        config[path] = .string(value)
        load(immediately: false)
    }

    public func choose(_ value: String, at path: String) {
        config[path] = .string(value)
        load(immediately: true)
    }

    public func setSecret(_ value: String, field: String) {
        secrets[field] = value
        load(immediately: false)
    }

    public func perform(_ action: String) {
        run(PluginRequest(command: .action, config: config, state: state, action: action))
    }

    public func save() {
        guard var draft else { return }
        for (field, store) in stores {
            let value = (secrets[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            store.write(value.isEmpty ? nil : value)
            secrets[field] = value
        }
        savedSecrets = secrets
        draft.plugin = PluginExport(pluginID: manifest.id, config: config, problem: form?.problem)
        self.draft = draft
        settings.update(draft)
    }

    public func discard() {
        draft = connector
        config = connector?.plugin?.config ?? .object([:])
        secrets = savedSecrets
        phase = .idle
        load(immediately: true)
    }

    private func edit(_ change: (inout Connector) -> Void) {
        guard var draft else { return }
        change(&draft)
        self.draft = draft
    }

    private func load(immediately: Bool) {
        refresh?.cancel()
        let request = PluginRequest(command: .form, config: config, state: state)
        guard !immediately else {
            run(request)
            return
        }
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.run(request)
        }
    }

    private func run(_ request: PluginRequest) {
        generation += 1
        let mine = generation
        phase = .working
        var request = request
        request.config = withSecretMarkers(request.config, present: secrets.keys.filter { !(secrets[$0] ?? "").isEmpty })
        let runner = runner
        let secrets = secrets
        Task { [weak self] in
            do {
                let response = try await runner(request, secrets)
                guard let self, mine == generation else { return }
                if let form = response.form { self.form = form }
                if let previews = response.previews { self.previews = previews }
                if let state = response.state { self.state = state }
                if let config = response.config, config != self.config {
                    self.config = restoringSecrets(config)
                }
                phase = .idle
                if request.command != .preview, response.form?.items.contains(where: wantsPreview) == true {
                    refreshPreviews()
                }
            } catch {
                guard let self, mine == generation else { return }
                phase = .failed("\(error)")
            }
        }
    }

    private func refreshPreviews() {
        previewing?.cancel()
        var request = PluginRequest(command: .preview, config: config, state: state)
        request.config = withSecretMarkers(request.config, present: secrets.keys.filter { !(secrets[$0] ?? "").isEmpty })
        let runner = runner
        let secrets = secrets
        let mine = generation
        previewing = Task { [weak self] in
            guard let response = try? await runner(request, secrets), !Task.isCancelled else { return }
            guard let self, mine == generation, let previews = response.previews else { return }
            self.previews = previews
        }
    }

    private func restoringSecrets(_ config: PluginJSON) -> PluginJSON {
        var config = config
        for field in manifest.secrets where config[field].string == secretMarker(field) {
            config[field] = .null
        }
        return config
    }
}

nonisolated private func wantsPreview(_ item: FormItem) -> Bool {
    if item.kind == .preview, item.text == nil, item.path != nil { return true }
    if (item.items ?? []).contains(where: wantsPreview) { return true }
    return (item.tabs ?? []).contains { $0.items.contains(where: wantsPreview) }
}
