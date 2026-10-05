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

    public var documents: [OKFDocument] { export.documents }

    public var links: [LinkTarget] { documents.map { LinkTarget(id: $0.id, name: $0.name) } }

    public var preview: [OKFPreviewFile] { okfPreview(export) }

    public var readiness: String? { okfProblem(export) }

    public func document(_ id: String) -> OKFDocument? {
        documents.first { $0.id == id }
    }

    @discardableResult
    public func addDocument() -> String {
        let document = OKFExport.newDocument(number: documents.count + 1)
        editExport { $0.documents.append(document) }
        return document.id
    }

    public func removeDocument(_ id: String) {
        editExport { $0.documents.removeAll { $0.id == id } }
    }

    public func updateDocument(_ id: String, _ change: (inout OKFDocument) -> Void) {
        editExport { export in
            guard let index = export.documents.firstIndex(where: { $0.id == id }) else { return }
            change(&export.documents[index])
        }
    }

    @discardableResult
    public func addProperty(to document: String) -> String? {
        guard self.document(document) != nil else { return nil }
        let property = OKFProperty(key: "", value: "")
        updateDocument(document) { $0.properties.append(property) }
        return property.id
    }

    public func updateProperty(_ id: String, in document: String, _ change: (inout OKFProperty) -> Void) {
        updateDocument(document) { document in
            guard let index = document.properties.firstIndex(where: { $0.id == id }) else { return }
            change(&document.properties[index])
        }
    }

    public func removeProperty(_ id: String, from document: String) {
        updateDocument(document) { document in
            document.properties.removeAll { $0.id == id && $0.key.trimmingCharacters(in: .whitespaces) != "type" }
        }
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
