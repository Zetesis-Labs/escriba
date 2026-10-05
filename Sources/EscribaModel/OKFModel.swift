import Foundation
import Observation
import EscribaCore
import EscribaOKF

@Observable
public final class OKFModel {
    public let id: UUID
    public private(set) var draft: Connector?
    @ObservationIgnored private let settings: AppSettings

    public init(connector id: UUID, settings: AppSettings) {
        self.id = id
        self.settings = settings
        draft = settings.connector(id)
    }

    public var connector: Connector? { settings.connector(id) }

    public var isDirty: Bool { draft != connector }

    public var export: OKFExport { draft?.okf ?? OKFExport(folder: "") }

    public var name: String {
        get { draft?.name ?? "" }
        set { edit { $0.name = newValue } }
    }

    public var publishes: Bool {
        get { draft?.enabled ?? false }
        set { edit { $0.enabled = newValue } }
    }

    public var folder: String {
        get { export.folder }
        set { editExport { $0.folder = newValue } }
    }

    public var separateTranscript: Bool {
        get { export.separateTranscript }
        set { editExport { $0.separateTranscript = newValue } }
    }

    public var template: BodyTemplate {
        get { export.template }
        set { editExport { $0.template = newValue } }
    }

    public var readiness: String? {
        export.isUsable ? nil : "Elige la carpeta donde guardar las notas."
    }

    public func save() {
        guard let draft else { return }
        settings.update(draft)
    }

    public func discard() {
        draft = connector
    }

    private func editExport(_ change: (inout OKFExport) -> Void) {
        edit { connector in
            var export = connector.okf ?? OKFExport(folder: "")
            change(&export)
            connector.okf = export
        }
    }

    private func edit(_ change: (inout Connector) -> Void) {
        guard var draft else { return }
        change(&draft)
        self.draft = draft
    }
}
