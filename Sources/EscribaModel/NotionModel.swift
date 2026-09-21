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
        tokens: TokenStore = keychainTokenStore(),
        client make: @escaping @Sendable (String) -> NotionClient = { makeNotionClient(token: $0) }
    ) {
        self.id = id
        self.settings = settings
        self.tokens = tokens
        self.make = make
        savedToken = tokens.read() ?? ""
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

    public var template: BodyTemplate {
        get { export?.template ?? .standard }
        set { edit { $0.notion?.template = newValue } }
    }

    public func insert(_ block: TemplateBlock, at index: Int) {
        var blocks = template.blocks
        blocks.insert(block, at: min(max(index, 0), blocks.count))
        template = BodyTemplate(blocks)
    }

    public func removeBlock(at index: Int) {
        var blocks = template.blocks
        guard blocks.indices.contains(index) else { return }
        blocks.remove(at: index)
        template = BodyTemplate(blocks)
    }

    public func moveBlocks(from source: IndexSet, to destination: Int) {
        template = BodyTemplate(moved(template.blocks, from: source, to: destination))
    }

    public func setText(_ text: String, at index: Int) {
        var blocks = template.blocks
        guard blocks.indices.contains(index) else { return }
        blocks[index] = .text(text)
        template = BodyTemplate(blocks)
    }

    public func apply(command typed: String, replacing index: Int) -> Bool {
        guard let block = templateBlock(forCommand: typed) else { return false }
        var blocks = template.blocks
        guard blocks.indices.contains(index) else { return false }
        blocks[index] = block
        template = BodyTemplate(blocks)
        return true
    }

    public var readiness: String? {
        guard !token.isEmpty else { return "Pega el token de tu integración de Notion." }
        guard let export else { return "Elige la base donde guardar." }
        return usabilityProblem(for: export.source)
            ?? (export.isUsable ? nil : "Falta decir qué propiedad hace de título.")
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
        let mapping = export.map {
            $0.source.id == source.id ? $0.mapping.pruned(to: source) : suggestedMapping(for: source)
        } ?? suggestedMapping(for: source)

        let template = export?.template ?? .standard
        edit { $0.notion = NotionExport(source: source, mapping: mapping, template: template) }
    }

    public func assign(_ field: NotionField, to property: String?) {
        edit { $0.notion?.mapping[field] = property }
    }

    public func property(for field: NotionField) -> String? {
        export?.mapping[field]
    }

    public func options(for field: NotionField) -> [NotionProperty] {
        guard let source = selected else { return [] }
        return compatible(field, in: source)
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
                source: fresh,
                mapping: current.mapping.pruned(to: fresh).fillingGaps(from: fresh),
                template: current.template)
        }
    }
}

nonisolated func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
    let moving = source.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    var rest = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
    let before = source.filter { $0 < destination }.count
    rest.insert(contentsOf: moving, at: min(max(destination - before, 0), rest.count))
    return rest
}
