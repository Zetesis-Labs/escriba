import Foundation

public struct ModelListing: Sendable, Equatable {
    public let identifiers: [String]
    public let selected: String?

    public init(identifiers: [String], selected: String?) {
        self.identifiers = identifiers
        self.selected = selected
    }

    public var isEmpty: Bool { identifiers.isEmpty }
}

public func parseModelListing(_ output: String) -> ModelListing {
    var identifiers: [String] = []
    var selected: String?

    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let isSelected = line.contains("▸")
        let cleaned = line.replacingOccurrences(of: "▸", with: " ")

        guard let identifier = cleaned.split(separator: " ", omittingEmptySubsequences: true).first,
              identifier.contains(":")
        else { continue }

        identifiers.append(String(identifier))
        if isSelected { selected = String(identifier) }
    }

    return ModelListing(identifiers: identifiers, selected: selected)
}
