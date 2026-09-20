import Foundation
import EscribaNotion

public struct Connector: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case notion

        public var label: String {
            switch self {
            case .notion: "Notion"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var enabled: Bool
    public var notion: NotionExport?

    public init(
        id: UUID = UUID(), name: String, kind: Kind = .notion, enabled: Bool = false,
        notion: NotionExport? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.notion = notion
    }

    public var key: String { id.uuidString }

    public var isReady: Bool { notion?.isUsable == true }

    public var isLive: Bool { enabled && isReady }
}

public func nextConnectorName(_ kind: Connector.Kind, among existing: [Connector]) -> String {
    let taken = Set(existing.map(\.name))
    guard taken.contains(kind.label) else { return kind.label }
    return (2...).lazy.map { "\(kind.label) \($0)" }.first { !taken.contains($0) } ?? kind.label
}
