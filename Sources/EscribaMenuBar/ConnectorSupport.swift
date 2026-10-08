import Foundation
import EscribaCore
import EscribaEngine
import EscribaJSC
import EscribaModel
import EscribaSystemKit

nonisolated func appTokenStore(account: String) -> TokenStore {
    if Paths.isolatedRoot != nil {
        return fileTokenStore(directory: Paths.applicationSupport.appending(path: "secrets"), account: account)
    }
    return defaultTokenStore(account: account)
}

nonisolated func connectorPermission(_ account: ConnectorAccount) -> ConnectorPermission {
    ConnectorPermission(account: account.id.uuidString, capability: account.capability,
                        origin: account.origin, folder: account.folder, enabled: account.enabled, allowedHeaders: account.allowedHeaders)
}

nonisolated func connectorServices(program: Result<ConnectorProgram, any Error>) -> ConnectorServices {
    ConnectorServices(run: { operation, provider, config, account in
        let request: [String: Any] = ["operation": operation, "provider": provider,
            "config": try JSONSerialization.jsonObject(with: Data(config.utf8)), "now": Date().ISO8601Format()]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let bridge = makeConnectorBridge(grant: ConnectorGrant(
            httpOrigin: account?.capability == "http" ? account?.origin : nil,
            folder: account?.capability == "folder" ? account?.folder.map { URL(fileURLWithPath: $0) } : nil,
            allowedHeaders: Set(account?.allowedHeaders ?? []),
            secret: {
                guard let account, account.enabled else { throw ConnectorHostError.denied }
                return appTokenStore(account: account.id.uuidString).read()
            }, checkpoint: { _ in throw ConnectorHostError.denied }))
        return try await javaScriptCoreConnectorRuntime().execute(program.get(), json, bridge)
    }, builtinFingerprint: (try? program.get().fingerprint) ?? "unavailable")
}

nonisolated func writeConnectorProject(folder: URL, destinations: [Connector], accounts: [ConnectorAccount], services: ConnectorServices) async throws {
    try BundledConnectors.install(intoProject: folder)
    let entry = folder.appending(path: "conectores.ts")
    guard !FileManager.default.fileExists(atPath: entry.path) else { return }
    var definitions: [[String: Any]] = []
    for destination in destinations where !destination.sourceMissing {
        definitions.append([
            "id": destination.key, "name": destination.name, "provider": destination.provider,
            "account": destination.accountID.uuidString,
            "configuration": try JSONSerialization.jsonObject(with: Data(destination.configurationJSON.utf8))])
    }
    for account in accounts where !destinations.contains(where: { $0.accountID == account.id }) {
        let config = String(decoding: try JSONSerialization.data(withJSONObject: ["folder": account.folder ?? ""]), as: UTF8.self)
        let template = try await services.run("template", account.provider, config, nil)
        guard let value = try JSONSerialization.jsonObject(with: Data(template.utf8)) as? [String: Any], let configuration = value["configuration"] else {
            throw ConnectorCatalogError.invalid("No se pudo crear el ejemplo del conector.")
        }
        definitions.append(["id": UUID().uuidString, "name": account.name, "provider": account.provider,
                            "account": account.id.uuidString, "configuration": configuration])
    }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: definitions, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    let source = """
    import { createProgram } from "@escriba/conectores";

    const program = createProgram(\(json));
    export const inspect = program.inspect;
    export const run = program.run;

    """
    try source.write(to: entry, atomically: true, encoding: .utf8)
}
