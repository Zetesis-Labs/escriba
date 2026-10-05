import AppKit
import EscribaCore
import EscribaModel
import EscribaOKF
import SwiftUI

struct OKFEditor: View {
    @Bindable var okf: OKFModel
    @State private var selection: String?

    private var selected: OKFDocument? {
        okf.documents.first { $0.id == selection } ?? okf.documents.first
    }

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $okf.name)
                Toggle("Exportar cada transcripción nueva", isOn: $okf.publishes)
                    .disabled(okf.readiness != nil)
                Text(okf.readiness ?? "Corregir hablantes, reprocesar o resumir reescribe los ficheros ya exportados.")
                    .font(.caption)
                    .foregroundStyle(okf.readiness == nil ? .secondary : Color.orange)
            }

            Section {
                HStack {
                    Text(okf.folder.isEmpty ? "Sin elegir" : abbreviated(okf.folder))
                        .foregroundStyle(okf.folder.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if !okf.folder.isEmpty {
                        Button("Mostrar en Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: okf.folder)])
                        }
                    }
                    Button("Elegir…") {
                        if let folder = chooseFolder() { okf.folder = folder }
                    }
                }
            } header: {
                Text("Carpeta del bundle")
            } footer: {
                Text("Escriba gestiona esta carpeta como un bundle OKF: escribe los documentos, un index.md en cada carpeta y log.md. Si va dentro de un bundle más grande, elige una subcarpeta propia.")
            }

            Section {
                HStack {
                    Picker("Documento", selection: tabSelection) {
                        ForEach(okf.documents) { document in
                            Text(document.name.isEmpty ? "Sin nombre" : document.name).tag(Optional(document.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button {
                        selection = okf.addDocument()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Añadir un documento")
                    Button {
                        if let selected { okf.removeDocument(selected.id) }
                        selection = okf.documents.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    .help("Quitar este documento")
                }
            } header: {
                Text("Documentos")
            } footer: {
                Text("Cada grabación escribe un fichero por documento. Para enlazarlos entre sí, inserta el dato «Enlace a…».")
            }

            if let document = selected {
                DocumentPage(okf: okf, document: document)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if okf.isDirty {
                    Text("Cambios sin guardar").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Descartar") { okf.discard() }
                    .disabled(!okf.isDirty)
                Button("Guardar") { okf.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!okf.isDirty)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var tabSelection: Binding<String?> {
        Binding(get: { selected?.id }, set: { selection = $0 })
    }
}

private struct DocumentPage: View {
    let okf: OKFModel
    let document: OKFDocument

    var body: some View {
        Section {
            TextField("Nombre", text: documentBinding(\.name))
            LabeledContent("Ruta") {
                TokenEditor(
                    source: documentBinding(\.path), context: .path, placeholder: "carpeta/[Día]-[Título].md")
            }
        } header: {
            Text("Documento")
        } footer: {
            Text("La ruta dentro del bundle. Escribe // para insertar un dato en ella; el título se pone sin tildes ni signos.")
        }

        Section {
            ForEach(document.properties) { property in
                PropertyRow(okf: okf, document: document, property: property)
            }
            Button("Añadir propiedad") { okf.addProperty(to: document.id) }
        } header: {
            Text("Propiedades")
        } footer: {
            Text("Son el frontmatter del fichero: clave y valor, con texto y datos mezclados. type es obligatorio en OKF. Escriba añade siempre escriba_key y generated para reconocer sus ficheros.")
        }

        Section {
            TokenEditor(
                source: documentBinding(\.body), context: .body, links: okf.links, current: document.id,
                placeholder: "Escribe aquí. Pulsa / para insertar un dato.", multiline: true)
        } header: {
            Text("Cuerpo")
        } footer: {
            Text("Escribe como en una página: Markdown, con # para los títulos. Pulsa / donde quieras para insertar un dato, o usa +. Una línea cuyos datos salen vacíos no se escribe.")
        }

        Section {
            if let file = okf.preview.first(where: { $0.documentID == document.id }) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(file.path, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(file.contents)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } header: {
            Text("Así queda")
        } footer: {
            Text("Con una grabación de ejemplo. Se actualiza mientras escribes, antes de guardar.")
        }
    }

    private func documentBinding(_ field: WritableKeyPath<OKFDocument, String>) -> Binding<String> {
        let (okf, id) = (okf, document.id)
        return Binding(
            get: { okf.document(id)?[keyPath: field] ?? "" },
            set: { value in okf.updateDocument(id) { $0[keyPath: field] = value } })
    }
}

private struct PropertyRow: View {
    let okf: OKFModel
    let document: OKFDocument
    let property: OKFProperty

    private var isType: Bool {
        property.key.trimmingCharacters(in: .whitespaces) == "type"
            && document.properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "type" }?.id == property.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isType {
                Text("type")
                    .font(.body.monospaced())
                    .frame(width: 130, alignment: .leading)
                    .padding(.top, 4)
            } else {
                TextField("clave", text: binding(\.key), prompt: Text("clave"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            TokenEditor(
                source: binding(\.value), context: .property, links: okf.links, current: document.id,
                placeholder: "valor")
            Button {
                okf.removeProperty(property.id, from: document.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .opacity(isType ? 0 : 1)
            .disabled(isType)
        }
    }

    private func binding(_ field: WritableKeyPath<OKFProperty, String>) -> Binding<String> {
        let (okf, documentID, propertyID) = (okf, document.id, property.id)
        return Binding(
            get: {
                okf.document(documentID)?.properties.first { $0.id == propertyID }?[keyPath: field] ?? ""
            },
            set: { value in okf.updateProperty(propertyID, in: documentID) { $0[keyPath: field] = value } })
    }
}
