import Foundation
import Observation
import EscribaEngine
import EscribaPluginKit
import EscribaPlugins

nonisolated public struct InstalledPlugin: Codable, Identifiable, Equatable, Sendable {
    public let manifest: PluginManifest
    public let file: String

    public var id: String { manifest.id }

    public init(manifest: PluginManifest, file: String) {
        self.manifest = manifest
        self.file = file
    }
}

nonisolated public struct PluginExport: Codable, Equatable, Sendable {
    public var pluginID: String
    public var config: PluginJSON
    public var problem: String?

    public init(pluginID: String, config: PluginJSON = .object([:]), problem: String? = "Sin configurar") {
        self.pluginID = pluginID
        self.config = config
        self.problem = problem
    }

    public var isUsable: Bool { problem == nil }
}

nonisolated public var defaultPluginsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/escriba/plugins")
}

nonisolated public func pluginSecretStore(connector: UUID, field: String) -> TokenStore {
    fileTokenStore(account: "plugin-\(connector.uuidString)-\(field)")
}

@Observable
public final class PluginsModel {
    public private(set) var installed: [InstalledPlugin] = []
    public private(set) var problem: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var modules: [String: PluginModule] = [:]

    public init(directory: URL = defaultPluginsDirectory) {
        self.directory = directory
        reload()
    }

    public func reload() {
        let index = directory.appending(path: "plugins.json")
        guard let data = FileManager.default.contents(atPath: index.path(percentEncoded: false)) else {
            installed = []
            return
        }
        do {
            installed = try JSONDecoder().decode([InstalledPlugin].self, from: data)
        } catch {
            Log.error("la lista de plugins no se pudo leer: \(error)")
            installed = []
        }
    }

    public func plugin(_ id: String) -> InstalledPlugin? {
        installed.first { $0.id == id }
    }

    public func module(_ id: String) throws -> PluginModule {
        if let module = modules[id] { return module }
        guard let plugin = plugin(id) else { throw HostError("el plugin \(id) no está instalado") }
        let module = try PluginModule(contentsOf: directory.appending(path: plugin.file))
        modules[id] = module
        return module
    }

    @discardableResult
    public func install(from source: URL) -> InstalledPlugin? {
        do {
            let module = try PluginModule(contentsOf: source)
            let manifest = try module.describe()
            let file = "\(manifest.id).wasm"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: file)
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            let plugin = InstalledPlugin(manifest: manifest, file: file)
            installed.removeAll { $0.id == plugin.id }
            installed.append(plugin)
            modules[plugin.id] = nil
            persist()
            problem = nil
            return plugin
        } catch {
            problem = "No se pudo importar el plugin: \(error)"
            return nil
        }
    }

    public func remove(_ id: String) {
        guard let plugin = plugin(id) else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: plugin.file))
        installed.removeAll { $0.id == id }
        modules[id] = nil
        persist()
    }

    public func dismissProblem() {
        problem = nil
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(installed).write(to: directory.appending(path: "plugins.json"), options: .atomic)
        } catch {
            Log.error("no se pudo guardar la lista de plugins: \(error)")
        }
    }
}
