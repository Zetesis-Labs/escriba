import AppKit
import EscribaCore
import EscribaModel
import EscribaPluginKit
import SwiftUI

struct PluginEditor: View {
    @Bindable var plugin: PluginConnectorModel

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $plugin.name)
                Toggle("Publicar cada transcripción nueva", isOn: $plugin.publishes)
                    .disabled(plugin.readiness != nil)
                HStack {
                    Text(plugin.readiness ?? "Corregir hablantes, reprocesar o resumir regenera lo ya publicado.")
                        .font(.caption)
                        .foregroundStyle(plugin.readiness == nil ? .secondary : Color.orange)
                    if plugin.phase.isWorking { ProgressView().controlSize(.mini) }
                }
                if let problem = plugin.phase.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Text("Plugin \(plugin.manifest.name) \(plugin.manifest.version), en WebAssembly.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array((plugin.form?.items ?? []).enumerated()), id: \.offset) { _, item in
                FormItemView(item: item, plugin: plugin)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if plugin.isDirty {
                    Text("Cambios sin guardar").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Descartar") { plugin.discard() }
                    .disabled(!plugin.isDirty)
                Button("Guardar") { plugin.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plugin.isDirty)
            }
            .padding(10)
            .background(.bar)
        }
    }
}

private struct FormItemView: View {
    let item: FormItem
    let plugin: PluginConnectorModel

    var body: some View {
        switch item.kind {
        case .section:
            Section {
                children
            } header: {
                if let header = item.header { Text(header) }
            } footer: {
                if let footer = item.footer { Text(footer) }
            }
        case .row:
            HStack(alignment: .top, spacing: 8) { children }
        case .text:
            textField
        case .secret:
            SecureField(item.label ?? "", text: secretBinding)
                .textFieldStyle(.roundedBorder)
            if let help = item.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        case .folder:
            folder
        case .choice:
            Picker(item.label ?? "", selection: choiceBinding) {
                Text(item.emptyLabel ?? "Sin elegir").tag("")
                ForEach(item.options ?? []) { option in
                    Text(option.label).tag(option.id)
                }
            }
        case .template:
            if let label = item.label {
                LabeledContent(label) { template }
            } else {
                template
            }
        case .button:
            if let symbol = item.symbol {
                Button {
                    plugin.perform(item.action ?? "")
                } label: {
                    Image(systemName: symbol)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .opacity(item.enabled == false ? 0 : 1)
                .disabled(item.enabled == false || plugin.phase.isWorking)
                .help(item.label ?? "")
            } else {
                Button(item.label ?? "", role: item.destructive == true ? .destructive : nil) {
                    plugin.perform(item.action ?? "")
                }
                .disabled(item.enabled == false || plugin.phase.isWorking)
            }
        case .label:
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text ?? "").font(item.monospaced == true ? .body.monospaced() : .body)
                if let help = item.help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: item.width.map { CGFloat($0) }, alignment: .leading)
            .padding(.top, 2)
        case .note:
            Text(item.text ?? "")
                .font(item.style == .plain ? .body : .caption)
                .foregroundStyle(item.style == .warning ? Color.orange : Color.secondary)
        case .preview:
            VStack(alignment: .leading, spacing: 6) {
                if let label = item.label {
                    Label(label, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                }
                Text(item.text ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        case .tabs:
            TabsView(item: item, plugin: plugin)
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(Array((item.items ?? []).enumerated()), id: \.offset) { _, child in
            FormItemView(item: child, plugin: plugin)
        }
    }

    @ViewBuilder private var textField: some View {
        if item.readOnly == true {
            Text(plugin.value(item.path ?? ""))
        } else if let label = item.label {
            TextField(label, text: textBinding)
        } else {
            TextField("", text: textBinding, prompt: item.placeholder.map(Text.init))
                .labelsHidden()
                .font(item.monospaced == true ? .body.monospaced() : .body)
                .textFieldStyle(.roundedBorder)
                .frame(width: item.width.map { CGFloat($0) })
        }
    }

    private var folder: some View {
        let path = plugin.value(item.path ?? "")
        return HStack {
            Text(path.isEmpty ? "Sin elegir" : abbreviated(path))
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !path.isEmpty, item.showInFinder != false {
                Button("Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button("Elegir…") {
                if let chosen = chooseFolder() { plugin.choose(chosen, at: item.path ?? "") }
            }
        }
    }

    private var template: some View {
        TokenEditor(
            source: textBinding, context: context, links: (item.links ?? []).map { LinkTarget(id: $0.id, name: $0.name) },
            current: item.current, placeholder: item.placeholder ?? "", multiline: item.multiline == true)
    }

    private var context: TemplateContext {
        switch item.context {
        case .property: .property
        case .path: .path
        default: .body
        }
    }

    private var textBinding: Binding<String> {
        let path = item.path ?? ""
        return Binding(get: { plugin.value(path) }, set: { plugin.setValue($0, at: path) })
    }

    private var choiceBinding: Binding<String> {
        let path = item.path ?? ""
        return Binding(get: { plugin.value(path) }, set: { plugin.choose($0, at: path) })
    }

    private var secretBinding: Binding<String> {
        let field = item.path ?? ""
        return Binding(get: { plugin.secrets[field] ?? "" }, set: { plugin.setSecret($0, field: field) })
    }
}

private struct TabsView: View {
    let item: FormItem
    let plugin: PluginConnectorModel
    @State private var selection: String?

    private var tabs: [FormTab] { item.tabs ?? [] }
    private var selected: FormTab? { tabs.first { $0.id == selection } ?? tabs.first }

    var body: some View {
        HStack {
            Picker("Documento", selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                ForEach(tabs, id: \.id) { tab in
                    Text(tab.label).tag(Optional(tab.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button {
                plugin.perform(item.addAction ?? "")
                selection = nil
            } label: {
                Image(systemName: "plus")
            }
            .help("Añadir un documento")
            Button {
                if let selected { plugin.perform("\(item.removeAction ?? "")/\(selected.id)") }
                selection = nil
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selected == nil)
            .help("Quitar este documento")
        }
        .disabled(plugin.phase.isWorking)
        if let selected {
            ForEach(Array(selected.items.enumerated()), id: \.offset) { _, child in
                FormItemView(item: child, plugin: plugin)
            }
        }
    }
}
