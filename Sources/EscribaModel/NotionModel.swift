import Foundation
import Observation
import EscribaCore
import EscribaNotion
import EscribaStore

@Observable
public final class NotionModel {
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
    public var token: String
    public private(set) var draft: Connector?
    @ObservationIgnored private var savedToken: String
    public private(set) var sources: [NotionDataSource] = []
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tokens: TokenStore
    @ObservationIgnored private let make: @Sendable (String) -> NotionClient

    public init(
        connector id: UUID,
        settings: AppSettings,
        tokens: TokenStore? = nil,
        client make: @escaping @Sendable (String) -> NotionClient = { makeNotionClient(token: $0) }
    ) {
        self.id = id
        self.settings = settings
        self.tokens = tokens ?? defaultTokenStore(account: id.uuidString)
        self.make = make
        savedToken = self.tokens.read() ?? ""
        token = savedToken
        draft = settings.connector(id)
    }

    public var connector: Connector? { settings.connector(id) }

    public var isDirty: Bool {
        draft != connector || token != savedToken
    }

    public var isConnected: Bool { !token.isEmpty && !sources.isEmpty }

    public var export: NotionExport? { draft?.notion }

    public var selected: NotionDataSource? { export?.source }

    public var name: String {
        get { draft?.name ?? "" }
        set { edit { $0.name = newValue } }
    }

    public var publishes: Bool {
        get { draft?.enabled ?? false }
        set { edit { $0.enabled = newValue } }
    }

    public func save() {
        guard let draft else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens.write(trimmed.isEmpty ? nil : trimmed)
        savedToken = trimmed
        token = trimmed
        settings.update(draft)
    }

    public func discard() {
        draft = connector
        token = savedToken
        phase = .idle
    }

    public var columns: [NotionProperty] {
        selected.map(writableProperties(of:)) ?? []
    }

    public func value(forColumn name: String) -> String {
        export?.columns[name] ?? ""
    }

    public func setValue(_ value: String, forColumn name: String) {
        edit { $0.notion?.columns[name] = value }
    }

    public var body: String {
        get { export?.body ?? NotionExport.standardBody }
        set { edit { $0.notion?.body = newValue } }
    }

    public var preview: NotionPreview? { export.map { notionPreview($0) } }

    public var readiness: String? {
        guard !token.isEmpty else { return "Pega el token de tu integración de Notion." }
        guard let export else { return "Elige la base donde guardar." }
        return notionProblem(export)
    }

    private func edit(_ change: (inout Connector) -> Void) {
        guard var draft else { return }
        change(&draft)
        self.draft = draft
    }

    public func connect() async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        phase = .working
        do {
            let found = try await make(token).dataSources()
            sources = found
            self.token = token
            phase = found.isEmpty
                ? .failed("La integración no tiene acceso a ninguna base. Compártele una desde Notion.")
                : .idle
            refreshSelection(among: found)
        } catch {
            sources = []
            phase = .failed(error.message)
        }
    }

    public func choose(_ source: NotionDataSource) {
        let columns = export.map {
            $0.source.id == source.id ? refreshedColumns($0.columns, for: source) : suggestedColumns(for: source)
        } ?? suggestedColumns(for: source)
        let body = export?.body ?? NotionExport.standardBody
        edit { $0.notion = NotionExport(source: source, columns: columns, body: body) }
    }

    public func disconnect() {
        tokens.write(nil)
        savedToken = ""
        token = ""
        sources = []
        phase = .idle
        edit {
            $0.notion = nil
            $0.enabled = false
        }
        if var stored = connector {
            stored.notion = nil
            stored.enabled = false
            settings.update(stored)
        }
    }

    private func refreshSelection(among found: [NotionDataSource]) {
        guard let current = export, let fresh = found.first(where: { $0.id == current.source.id })
        else { return }
        edit {
            $0.notion = NotionExport(
                source: fresh, columns: refreshedColumns(current.columns, for: fresh), body: current.body)
        }
    }
}
