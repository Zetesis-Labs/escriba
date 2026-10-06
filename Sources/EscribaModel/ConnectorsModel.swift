import Foundation
import Observation
import EscribaNotion
import EscribaOKF
import EscribaPluginKit
import EscribaPlugins

@Observable
public final class ConnectorsModel {
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tokens: @Sendable (UUID) -> TokenStore
    @ObservationIgnored private let make: @Sendable (String) -> NotionClient
    @ObservationIgnored private var editors: [UUID: NotionModel] = [:]
    @ObservationIgnored private var okfEditors: [UUID: OKFModel] = [:]
    @ObservationIgnored private var pluginEditors: [UUID: PluginConnectorModel] = [:]
    public let plugins: PluginsModel

    public init(
        settings: AppSettings,
        tokens: @escaping @Sendable (UUID) -> TokenStore = { defaultTokenStore(account: $0.uuidString) },
        client make: @escaping @Sendable (String) -> NotionClient = { makeNotionClient(token: $0) },
        plugins: PluginsModel = PluginsModel()
    ) {
        self.settings = settings
        self.tokens = tokens
        self.make = make
        self.plugins = plugins
    }

    public var connectors: [Connector] { settings.connectors }

    @discardableResult
    public func add(_ kind: Connector.Kind = .notion) -> Connector {
        let connector = Connector(
            name: nextConnectorName(kind, among: settings.connectors), kind: kind,
            okf: kind == .okf ? OKFExport(folder: "") : nil)
        settings.connectors.append(connector)
        return connector
    }

    @discardableResult
    public func add(plugin: InstalledPlugin) -> Connector {
        let connector = Connector(
            name: nextConnectorName(plugin.manifest.name, among: settings.connectors), kind: .plugin,
            plugin: PluginExport(pluginID: plugin.id))
        settings.connectors.append(connector)
        return connector
    }

    public func remove(_ id: UUID) {
        editors[id]?.disconnect()
        editors[id] = nil
        okfEditors[id] = nil
        if let connector = settings.connector(id), let plugin = connector.plugin,
            let manifest = plugins.plugin(plugin.pluginID)?.manifest
        {
            for field in manifest.secrets { pluginSecretStore(connector: id, field: field).write(nil) }
        }
        pluginEditors[id] = nil
        settings.connectors.removeAll { $0.id == id }
    }

    public func pluginEditor(for id: UUID) -> PluginConnectorModel? {
        if let editor = pluginEditors[id] { return editor }
        guard let export = settings.connector(id)?.plugin, let plugin = plugins.plugin(export.pluginID) else { return nil }
        let plugins = plugins
        let editor = PluginConnectorModel(
            connector: id, manifest: plugin.manifest, settings: settings,
            runner: { request, secrets in
                let module = try await MainActor.run { try plugins.module(plugin.id) }
                return try await PluginBinding(module: module, manifest: plugin.manifest, config: request.config, secrets: secrets).run(request)
            })
        pluginEditors[id] = editor
        return editor
    }

    public func binding(for connector: Connector, module: PluginModule) -> PluginBinding? {
        guard let export = connector.plugin, let plugin = plugins.plugin(export.pluginID) else { return nil }
        let secrets = Dictionary(uniqueKeysWithValues: plugin.manifest.secrets.compactMap { field in
            pluginSecretStore(connector: connector.id, field: field).read().map { (field, $0) }
        })
        return PluginBinding(module: module, manifest: plugin.manifest, config: export.config, secrets: secrets)
    }

    public func editor(for id: UUID) -> NotionModel {
        if let editor = editors[id] { return editor }
        let editor = NotionModel(connector: id, settings: settings, tokens: tokens(id), client: make)
        editors[id] = editor
        return editor
    }

    public func okfEditor(for id: UUID) -> OKFModel {
        if let editor = okfEditors[id] { return editor }
        let editor = OKFModel(connector: id, settings: settings)
        okfEditors[id] = editor
        return editor
    }
}
