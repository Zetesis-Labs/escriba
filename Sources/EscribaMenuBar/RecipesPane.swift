import AppKit
import EscribaCore
import EscribaEngine
import EscribaModel
import SwiftUI

struct RecipesPane: View {
    @Bindable var settings: AppSettings
    let recipes: RecipeProjectModel
    let library: LibraryModel?
    @State private var selected: String?
    @State private var removing: FormRecipe?

    private var book: RecipeBook { settings.recipeBook }

    private var statuses: [RecipeStatus] { recipes.report?.recipes ?? [] }

    private var listing: [RecipeListing] {
        book.listing(code: statuses.map { RecipeCodeEntry(key: $0.key, name: $0.name) })
    }

    var body: some View {
        ListDetailLayout(listWidth: 260) {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    Section("De formulario") {
                        ForEach(listing.filter { $0.kind == .form }) { recipe in
                            RecipeRow(recipe: recipe, subtitle: formSubtitle(recipe.key))
                                .tag(recipe.key)
                                .contextMenu {
                                    Button("Duplicar") {
                                        selected = settings.recipeBook.duplicate(recipe.key, as: UUID().uuidString)?.key
                                    }
                                    Button("Usar por defecto") { settings.recipeBook.makeDefault(recipe.key) }
                                        .disabled(recipe.isDefault)
                                    Divider()
                                    Button("Quitar…") { removing = book.form(recipe.key) }
                                        .disabled(book.forms.count < 2)
                                }
                        }
                    }
                    Section("De código") {
                        ForEach(listing.filter { $0.kind == .code }) { recipe in
                            RecipeRow(recipe: recipe, subtitle: codeSubtitle(recipe.key))
                                .tag(recipe.key)
                                .contextMenu {
                                    Button("Guardar como receta de formulario") { saveAsForm(recipe.key) }
                                        .disabled(statuses.first { $0.key == recipe.key }?.active == nil)
                                }
                        }
                        ProjectFooter(settings: settings, recipes: recipes)
                    }
                }
                .listStyle(.inset)
                .onAppear { if selected == nil { selected = book.defaultKey } }
                if let missing {
                    Label(missing, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        selected = settings.recipeBook.add(key: UUID().uuidString, name: "Receta nueva").key
                    } label: { ListBarIcon(systemName: "plus") }
                    .help("Nueva receta de formulario")
                    Button {
                        removing = selectedForm
                    } label: { ListBarIcon(systemName: "minus") }
                    .help("Quitar")
                    .disabled(selectedForm == nil || book.forms.count < 2)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
        } detail: {
            if let key = selected, let form = book.form(key) {
                FormRecipeEditor(
                    settings: settings, recipe: form, base: form.base.flatMap { base in statuses.first { $0.key == base } },
                    library: library)
                    .id(key)
            } else if let key = selected, let status = statuses.first(where: { $0.key == key }) {
                CodeRecipeDetail(
                    settings: settings, status: status, folder: settings.recipesFolderPath, library: library,
                    onSaveAsForm: { saveAsForm(key) })
                    .id(key)
            } else {
                ContentUnavailableView(
                    "Sin receta elegida", systemImage: "curlybraces",
                    description: Text("Elige una de la lista, o crea una con +."))
            }
        }
        .navigationTitle("Recetas")
        .confirmationDialog(
            "¿Quitar «\(removing?.name ?? "")»?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Quitar", role: .destructive) {
                if let removing { settings.recipeBook.remove(removing.key) }
                selected = settings.recipeBook.defaultKey
                removing = nil
            }
        } message: {
            Text(removing?.key == book.defaultKey
                ? "Es la receta por defecto: pasará a serlo «\(book.forms.first { $0.key != removing?.key }?.name ?? "")»."
                : "Las notas ya procesadas no cambian.")
        }
    }

    private var selectedForm: FormRecipe? {
        selected.flatMap { book.form($0) }
    }

    private var missing: String? {
        guard recipes.phase != .preparing, recipes.phase != .building,
            !listing.contains(where: { $0.key == book.defaultKey })
        else { return nil }
        return "La receta por defecto «\(book.defaultKey)» ya no está en el proyecto: las notas esperan hasta que elijas otra."
    }

    private func saveAsForm(_ key: String) {
        let name = statuses.first { $0.key == key }?.name ?? key
        selected = settings.recipeBook.add(
            key: UUID().uuidString, name: "\(name) (copia)", base: key, values: settings.recipeBook.values[key]
        ).key
    }

    private func formSubtitle(_ key: String) -> String {
        guard let base = book.form(key)?.base else { return "De serie · se configura aquí" }
        guard let status = statuses.first(where: { $0.key == base }) else { return "Su receta «\(base)» ya no está" }
        return "De «\(status.name ?? base)» · se configura aquí"
    }

    private func codeSubtitle(_ key: String) -> String {
        guard let status = statuses.first(where: { $0.key == key }) else { return "Código" }
        return status.issues.isEmpty ? "Código · \(key)" : "No compila · \(key)"
    }
}

private struct RecipeRow: View {
    let recipe: RecipeListing
    let subtitle: String

    var body: some View {
        HStack {
            Image(systemName: recipe.kind == .form ? "slider.horizontal.3" : "curlybraces")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading) {
                Text(recipe.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if recipe.isDefault {
                Text("Por defecto")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .help("Procesa todo lo que entra")
            }
        }
    }
}

private struct DefaultRecipeSection: View {
    @Bindable var settings: AppSettings
    let key: String
    let isUsable: Bool

    var body: some View {
        if settings.recipeBook.defaultKey == key {
            Label("Es la receta por defecto: procesa todo lo que entra.", systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
        } else {
            Button("Usar por defecto") { settings.recipeBook.makeDefault(key) }
                .disabled(!isUsable)
        }
    }
}

private struct FormRecipeEditor: View {
    @Bindable var settings: AppSettings
    let recipe: FormRecipe
    let base: RecipeStatus?
    let library: LibraryModel?
    @State private var name: String

    init(settings: AppSettings, recipe: FormRecipe, base: RecipeStatus?, library: LibraryModel?) {
        self.settings = settings
        self.recipe = recipe
        self.base = base
        self.library = library
        _name = State(initialValue: recipe.name)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $name)
                    .onChange(of: name) { _, value in settings.recipeBook.rename(recipe.key, to: value) }
                DefaultRecipeSection(settings: settings, key: recipe.key, isUsable: true)
            } footer: {
                Text("\(origin) Desde una receta de código se llama con escriba.receta(\"\(name)\").procesar(audio).")
            }
            RecipeParameters(settings: settings, key: recipe.key, fingerprint: base?.active)
            if let library {
                RecipeTestSection(library: library, recipe: recipe.key)
                RecipeRunsSection(library: library, recipe: recipe.key)
            }
        }
        .formStyle(.grouped)
    }

    private var origin: String {
        guard let key = recipe.base else {
            return "Ejecuta el código de serie de Escriba, el de «Por defecto», con estos valores."
        }
        guard let base else { return "Su receta de código, «\(key)», ya no está en el proyecto: no se puede usar." }
        return "Ejecuta el código de «\(base.name ?? key)» con estos valores: si cambias su receta.ts, cambia también esta."
    }
}

private struct CodeRecipeDetail: View {
    @Bindable var settings: AppSettings
    let status: RecipeStatus
    let folder: String?
    let library: LibraryModel?
    let onSaveAsForm: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Nombre", value: status.name ?? status.key)
                LabeledContent("Clave", value: status.key)
                DefaultRecipeSection(settings: settings, key: status.key, isUsable: status.active != nil)
                Button("Guardar como receta de formulario", action: onSaveAsForm)
                    .disabled(status.active == nil)
                    .help("Crea una receta con nombre propio que ejecuta este código con los valores que le dejes")
                if status.active == nil {
                    Text("Todavía no ha compilado nunca: no se puede usar hasta que compile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Se edita en la carpeta del proyecto, con tu editor o un agente. Escriba la compila al guardar.")
            }
            if status.active != nil {
                RecipeParameters(settings: settings, key: status.key, fingerprint: status.active)
            }
            Section("Compilación") {
                Text(recipeStatusLine(status))
                    .foregroundStyle(status.issues.isEmpty ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                if let folder {
                    Button("Abrir en el Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder).appending(path: "recetas/\(status.key)"))
                    }
                }
            }
            if let library, status.active != nil {
                RecipeTestSection(library: library, recipe: status.key)
            }
            if let library {
                RecipeRunsSection(library: library, recipe: status.key)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecipeParameters: View {
    @Bindable var settings: AppSettings
    let key: String
    let fingerprint: String?
    @Environment(\.recipeForms) private var forms
    @State private var load: RecipeFormLoad?

    var body: some View {
        Group {
            switch load {
            case .form(let form)?:
                RecipeFormSections(form: form, values: values(form))
                Section {
                    Button("Volver a los valores de serie") { settings.recipeBook.setValues(nil, for: key) }
                        .disabled(settings.recipeBook.values[key] == nil)
                } footer: {
                    Text("Lo que cambias aquí se guarda para esta receta y vale para todas las notas que procese, también cuando otra receta se la pasa. Los valores de serie y las opciones salen de \(recipeFormExport), en su código.")
                }
            case .problem(let problem)?:
                Section("Parámetros") {
                    Text(problem)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            case .noForm?, nil:
                EmptyView()
            }
        }
        .task(id: reloadKey) { load = await forms?.load(key) }
    }

    private var reloadKey: String {
        let names = settings.recipeBook.forms.map(\.name).joined(separator: "|")
        return "\(fingerprint ?? "")|\(forms?.id.uuidString ?? "")|\(names)"
    }

    private func values(_ form: RecipeForm) -> Binding<DataValue> {
        Binding(
            get: { recipeFormValues(form, saved: savedRecipeValues(settings.recipeBook, key)) },
            set: { settings.recipeBook.setValues(recipeFormOverrides(form, values: $0).map { dataText($0) }, for: key) })
    }
}

func savedRecipeValues(_ book: RecipeBook, _ key: String) -> DataValue? {
    book.values[key].flatMap { try? parseData($0) }
}

private struct ProjectFooter: View {
    @Bindable var settings: AppSettings
    let recipes: RecipeProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(settings.recipesFolderPath.map(abbreviated) ?? "Sin carpeta de proyecto")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Button(settings.recipesFolderPath == nil ? "Elegir carpeta…" : "Cambiar…") { choose() }
                if let path = settings.recipesFolderPath {
                    Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            }
            .controlSize(.small)
            phase
        }
        .padding(.vertical, 2)
        .selectionDisabled()
    }

    @ViewBuilder private var phase: some View {
        switch recipes.phase {
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Preparando el compilador (14 MB, solo la primera vez)…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .building:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Compilando…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        case .idle, .ready:
            EmptyView()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Paths.documents
        panel.prompt = "Usar esta carpeta"
        panel.message = "Elige una carpeta vacía para crear el proyecto de recetas, o una que ya lo tenga. Es tuya: puedes versionarla con git; Escriba solo escribe la plantilla al crearla y .escriba/estado.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.recipesFolderPath = url.path(percentEncoded: false)
        Task { await recipes.open(url) }
    }
}
