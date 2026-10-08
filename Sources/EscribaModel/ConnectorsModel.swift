import Foundation
import Observation

nonisolated public struct ConnectorServices: Sendable {
    public var run: @Sendable (_ operation: String, _ provider: String, _ configJSON: String, _ account: ConnectorAccount?) async throws -> String
    public var builtinFingerprint: String
    public init(run: @escaping @Sendable (String, String, String, ConnectorAccount?) async throws -> String,
                builtinFingerprint: String) {
        self.run = run; self.builtinFingerprint = builtinFingerprint
    }
}

nonisolated public struct ConnectorProvider: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var capability: String
    public var origin: String?
    public var description: String?
    public var configurationSchemaJSON: String?
    public var inputSchemaJSON: String?
    public var allowedHeaders: [String]
}

nonisolated public enum ConnectorCatalogError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

@Observable
public final class ConnectorsModel {
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tokens: @Sendable (UUID) -> TokenStore
    @ObservationIgnored private let services: ConnectorServices
    public private(set) var providers: [ConnectorProvider] = []
    public private(set) var problem: String?

    public init(settings: AppSettings,
                tokens: @escaping @Sendable (UUID) -> TokenStore = { defaultTokenStore(account: $0.uuidString) },
                services: ConnectorServices) {
        self.settings = settings; self.tokens = tokens; self.services = services
    }
    public var connectors: [Connector] { settings.connectors }
    public var accounts: [ConnectorAccount] { settings.connectorAccounts }

    public func initialize() async throws {
        do {
            let manifest = try object(await services.run("manifest", "", "{}", nil))
            guard let entries = manifest["providers"] as? [[String: Any]] else { throw invalidCatalog() }
            let providers = try entries.map { entry -> ConnectorProvider in
                guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                      let capability = entry["capability"] as? String,
                      ["http", "folder"].contains(capability) else { throw invalidCatalog() }
                return ConnectorProvider(id: id, name: name, capability: capability,
                    origin: entry["origin"] as? String, description: entry["description"] as? String,
                    configurationSchemaJSON: try entry["configurationSchema"].map(json),
                    inputSchemaJSON: try entry["inputSchema"].map(json),
                    allowedHeaders: entry["allowedHeaders"] as? [String] ?? ["content-type", "accept"])
            }
            self.providers = providers
            var destinations = settings.connectors
            var accounts = settings.connectorAccounts
            for index in destinations.indices where destinations[index].legacy {
                var destination = destinations[index]
                do {
                let migrated = try object(await services.run("migrate", destination.provider, destination.configurationJSON, nil))
                guard let configuration = migrated["configuration"],
                      let grant = migrated["account"] as? [String: Any],
                      let capability = grant["capability"] as? String,
                      ["http", "folder"].contains(capability) else { throw invalidCatalog() }
                if !accounts.contains(where: { $0.id == destination.accountID }) {
                    accounts.append(ConnectorAccount(id: destination.accountID, name: destination.name,
                        provider: destination.provider, capability: capability,
                        origin: grant["origin"] as? String, folder: grant["folder"] as? String,
                        enabled: destination.enabled,
                        allowedHeaders: grant["allowedHeaders"] as? [String] ?? providers.first { $0.id == destination.provider }?.allowedHeaders ?? ["content-type", "accept"]))
                }
                destination.configurationJSON = try json(configuration)
                destination.programFingerprint = services.builtinFingerprint
                destination.inputSchemaJSON = providers.first { $0.id == destination.provider }?.inputSchemaJSON
                destination.legacy = false
                destination.migrationProblem = nil
                } catch {
                    destination.migrationProblem = error.localizedDescription
                }
                destinations[index] = destination
            }
            settings.connectorAccounts = accounts
            settings.connectors = destinations
            self.providers = providers
            let pending = destinations.compactMap { destination in
                destination.migrationProblem.map { "\(destination.name): \($0)" }
            }
            problem = pending.isEmpty ? nil : pending.joined(separator: "\n")
        } catch {
            problem = error.localizedDescription
            throw error
        }
    }

    @discardableResult public func addAccount(provider: String) throws -> ConnectorAccount {
        guard let descriptor = providers.first(where: { $0.id == provider }) else { throw invalidCatalog() }
        let taken = Set(accounts.map(\.name))
        let name = taken.contains(descriptor.name)
            ? (2...).lazy.map { "\(descriptor.name) \($0)" }.first { !taken.contains($0) } ?? descriptor.name
            : descriptor.name
        let account = ConnectorAccount(name: name, provider: provider, capability: descriptor.capability, origin: descriptor.origin, allowedHeaders: descriptor.allowedHeaders)
        settings.connectorAccounts.append(account)
        return account
    }

    public func updateAccount(_ account: ConnectorAccount) {
        guard let index = settings.connectorAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        settings.connectorAccounts[index] = account
    }

    public func removeAccount(_ id: UUID) throws {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.enabled = false
        updateAccount(account)
        try tokens(id).save(nil)
    }

    public func saveToken(_ token: String?, account: UUID) throws {
        guard accounts.contains(where: { $0.id == account && $0.capability == "http" }) else {
            throw ConnectorCatalogError.invalid("La cuenta no admite credenciales HTTP.")
        }
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        try tokens(account).save(value?.isEmpty == true ? nil : value)
    }

    public func installDestinations(inspectJSON: String, fingerprint: String) throws {
        settings.connectors = try plannedDestinations(inspectJSON: inspectJSON, fingerprint: fingerprint)
    }

    public func validateDestinations(inspectJSON: String, fingerprint: String) throws {
        _ = try plannedDestinations(inspectJSON: inspectJSON, fingerprint: fingerprint)
    }

    private func plannedDestinations(inspectJSON: String, fingerprint: String) throws -> [Connector] {
        let inspection = try object(inspectJSON)
        guard let entries = inspection["destinations"] as? [[String: Any]] else { throw invalidCatalog() }
        var ids: Set<String> = []
        var updated = settings.connectors
        for entry in entries {
            guard let id = entry["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let name = entry["name"] as? String, let provider = entry["provider"] as? String,
                  let accountReference = entry["account"] as? String,
                  let configuration = entry["configuration"] else { throw invalidCatalog() }
            let candidates = accounts.filter { $0.id.uuidString == accountReference || $0.name == accountReference }
            guard candidates.count == 1, let account = candidates.first, account.provider == provider else {
                throw ConnectorCatalogError.invalid("El destino «\(name)» necesita una cuenta «\(accountReference)» del proveedor «\(provider)».")
            }
            let existing = updated.first { $0.key == id }
            if let existing, existing.destinationID == nil,
               existing.accountID != account.id || existing.provider != provider {
                throw ConnectorCatalogError.invalid("El identificador «\(id)» ya pertenece a otro destino migrado.")
            }
            if existing == nil, accounts.contains(where: { $0.id.uuidString == id }) {
                throw ConnectorCatalogError.invalid("El identificador «\(id)» está reservado para una cuenta.")
            }
            let connector = Connector(id: existing?.id ?? UUID(), destinationID: id, name: name,
                provider: provider, accountID: account.id, enabled: existing?.enabled ?? true,
                configurationJSON: try json(configuration), programFingerprint: fingerprint,
                inputSchemaJSON: try entry["inputSchema"].map(json), description: entry["description"] as? String)
            if let index = updated.firstIndex(where: { $0.key == id }) { updated[index] = connector }
            else { updated.append(connector) }
        }
        for index in updated.indices {
            if let id = updated[index].destinationID, !ids.contains(id) { updated[index].sourceMissing = true }
        }
        return updated
    }

    private func object(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw invalidCatalog() }
        return object
    }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    private func invalidCatalog() -> ConnectorCatalogError { .invalid("El catálogo de conectores no es válido.") }
}
