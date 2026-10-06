import Foundation
import EscribaNotion
import EscribaOKF
import EscribaPluginKit

public struct Connector: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case notion
        case okf
        case plugin

        public static let native: [Kind] = [.notion, .okf]

        public var label: String {
            switch self {
            case .notion: "Notion"
            case .okf: "OKF"
            case .plugin: "Plugin"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var enabled: Bool
    public var notion: NotionExport?
    public var okf: OKFExport?
    public var plugin: PluginExport?

    public init(
        id: UUID = UUID(), name: String, kind: Kind = .notion, enabled: Bool = false,
        notion: NotionExport? = nil, okf: OKFExport? = nil, plugin: PluginExport? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.notion = notion
        self.okf = okf
        self.plugin = plugin
    }

    public var key: String { id.uuidString }

    public var isReady: Bool {
        switch kind {
        case .notion: notion?.isUsable == true
        case .okf: okf?.isUsable == true
        case .plugin: plugin?.isUsable == true
        }
    }

    public var isLive: Bool { enabled && isReady }
}

public func nextConnectorName(_ kind: Connector.Kind, among existing: [Connector]) -> String {
    nextConnectorName(kind.label, among: existing)
}

public func nextConnectorName(_ base: String, among existing: [Connector]) -> String {
    let taken = Set(existing.map(\.name))
    guard taken.contains(base) else { return base }
    return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
}
