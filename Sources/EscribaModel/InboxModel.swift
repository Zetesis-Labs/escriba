import Foundation
import Observation
import EscribaCore
import EscribaSystemKit

public struct ImportOutcome: Equatable, Sendable {
    public let added: [String]
    public let rejected: [String]
    public let failed: [String]

    public init(added: [String], rejected: [String], failed: [String]) {
        self.added = added
        self.rejected = rejected
        self.failed = failed
    }
}

@Observable
public final class InboxModel {
    public private(set) var notice: String?

    @ObservationIgnored private let inbox: Inbox
    @ObservationIgnored private let wake: () -> Void

    public init(inbox: Inbox, wake: @escaping () -> Void) {
        self.inbox = inbox
        self.wake = wake
    }

    @discardableResult
    public func add(_ urls: [URL], recipe: String? = nil) -> ImportOutcome {
        let plan = dropPlan(urls, taken: (try? inbox.names()) ?? [])
        var added: [String] = []
        var failed: [String] = []
        for file in plan.accepted {
            do {
                try inbox.importFile(file.source, file.name, recipe)
                added.append(file.name)
            } catch {
                failed.append(file.source.lastPathComponent)
            }
        }
        let outcome = ImportOutcome(added: added, rejected: plan.rejected.map(\.lastPathComponent), failed: failed)
        if !added.isEmpty { wake() }
        notice = importNotice(outcome)
        return outcome
    }

    public func dismissNotice() {
        notice = nil
    }
}

public func importNotice(_ outcome: ImportOutcome) -> String? {
    var parts: [String] = []
    switch outcome.added.count {
    case 0: break
    case 1: parts.append("«\(outcome.added[0])» añadida; se transcribe enseguida.")
    default: parts.append("\(outcome.added.count) grabaciones añadidas; se transcriben enseguida.")
    }
    switch outcome.rejected.count {
    case 0: break
    case 1: parts.append("«\(outcome.rejected[0])» no es un audio que Escriba sepa leer.")
    default: parts.append("\(outcome.rejected.count) ficheros no son audio que Escriba sepa leer.")
    }
    switch outcome.failed.count {
    case 0: break
    case 1: parts.append("No se pudo copiar «\(outcome.failed[0])».")
    default: parts.append("No se pudieron copiar \(outcome.failed.count) ficheros.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}
