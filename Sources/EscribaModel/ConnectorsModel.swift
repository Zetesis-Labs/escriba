import Foundation
import Observation
import EscribaNotion
import EscribaOKF

@Observable
public final class ConnectorsModel {
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tokens: @Sendable (UUID) -> TokenStore
    @ObservationIgnored private let make: @Sendable (String) -> NotionClient
    @ObservationIgnored private var editors: [UUID: NotionModel] = [:]
    @ObservationIgnored private var okfEditors: [UUID: OKFModel] = [:]

    public init(
        settings: AppSettings,
        tokens: @escaping @Sendable (UUID) -> TokenStore = { defaultTokenStore(account: $0.uuidString) },
        client make: @escaping @Sendable (String) -> NotionClient = { makeNotionClient(token: $0) }
    ) {
        self.settings = settings
        self.tokens = tokens
        self.make = make
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

    public func remove(_ id: UUID) {
        editors[id]?.disconnect()
        editors[id] = nil
        okfEditors[id] = nil
        settings.connectors.removeAll { $0.id == id }
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
