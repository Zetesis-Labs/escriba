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
                            RecipeRow(recipe: recipe, subtitle: "Se configura aquí")
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
                            RecipeRow(recipe: recipe, subtitle: codeSubtitle(recipe.key)).tag(recipe.key)
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
                        selected = settings.recipeBook.add(
                            key: UUID().uuidString, name: "Receta nueva", settings: .standard
                        ).key
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
                FormRecipeEditor(settings: settings, recipe: form, library: library)
                    .id(key)
            } else if let key = selected, let status = statuses.first(where: { $0.key == key }) {
                CodeRecipeDetail(settings: settings, status: status, folder: settings.recipesFolderPath, library: library)
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
    let library: LibraryModel?
    @State private var name: String

    init(settings: AppSettings, recipe: FormRecipe, library: LibraryModel?) {
        self.settings = settings
        self.recipe = recipe
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
                Text("Las recetas de formulario ejecutan el mismo código que «Por defecto» con estos parámetros. Desde una receta de código se llaman con escriba.receta(\"\(name)\").procesar(audio).")
            }
            RecipeParametersFields(settings: settings, parameters: parameters)
            if let library {
                RecipeTestSection(library: library, recipe: recipe.key)
                RecipeRunsSection(library: library, recipe: recipe.key)
            }
        }
        .formStyle(.grouped)
    }

    private var parameters: Binding<DefaultRecipeSettings> {
        Binding(
            get: { settings.recipeBook.form(recipe.key)?.settings ?? recipe.settings },
            set: { settings.recipeBook.update(recipe.key, settings: $0) })
    }
}

private struct CodeRecipeDetail: View {
    @Bindable var settings: AppSettings
    let status: RecipeStatus
    let folder: String?
    let library: LibraryModel?

    var body: some View {
        Form {
            Section {
                LabeledContent("Nombre", value: status.name ?? status.key)
                LabeledContent("Clave", value: status.key)
                DefaultRecipeSection(settings: settings, key: status.key, isUsable: status.active != nil)
                if status.active == nil {
                    Text("Todavía no ha compilado nunca: no se puede usar hasta que compile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Se edita en la carpeta del proyecto, con tu editor o un agente. Escriba la compila al guardar.")
            }
            if status.active != nil {
                CodeRecipeParameters(settings: settings, key: status.key, fingerprint: status.active)
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

private struct CodeRecipeParameters: View {
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
                    Button("Volver a los valores del script") { settings.recipeBook.setValues(nil, for: key) }
                        .disabled(settings.recipeBook.values[key] == nil)
                } footer: {
                    Text("Lo que cambias aquí se guarda para esta receta y vale para todas las notas que procese, también cuando otra receta se la pasa. Los valores de serie y las opciones los pone su \(recipeFormExport).")
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

struct RecipeParametersFields: View {
    @Bindable var settings: AppSettings
    let parameters: Binding<DefaultRecipeSettings>

    var body: some View {
        Section("Transcripción") {
            Picker("Transcribe con", selection: parameters.stt) {
                ForEach(settings.sttResolvers.resolvers) { resolver in
                    Text(resolver.name).tag(resolver.recipeKey(role: .stt))
                }
            }
            Picker("Idioma", selection: parameters.language) {
                Text("Español").tag(String?.some("es"))
                Text("English").tag(String?.some("en"))
                Text("Detectar en cada nota").tag(String?.none)
            }
            Picker("Hablantes", selection: speakers) {
                Text("No detectar").tag(-1)
                Text("Detectar").tag(0)
                ForEach(2...6, id: \.self) { count in
                    Text("\(count) hablantes").tag(count)
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        Section("Resumen") {
            Toggle("Resumir", isOn: parameters.summarize)
            if parameters.wrappedValue.summarize {
                Picker("Resume con", selection: parameters.llm) {
                    ForEach(settings.llmResolvers.resolvers) { resolver in
                        Text(resolver.name).tag(resolver.recipeKey(role: .llm))
                    }
                }
                TextField("Prompt", text: prompt, prompt: Text("El de serie"), axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        Section("Publica en") {
            if settings.connectors.isEmpty {
                Text("No hay conectores").foregroundStyle(.secondary)
            }
            ForEach(settings.connectors) { connector in
                Toggle(
                    connector.isLive ? connector.name : "\(connector.name) (apagado)",
                    isOn: publishes(connector.key))
            }
        }
    }

    private var speakers: Binding<Int> {
        Binding(
            get: {
                let current = parameters.wrappedValue
                return current.detectSpeakers ? current.speakerCount ?? 0 : -1
            },
            set: { value in
                parameters.wrappedValue.detectSpeakers = value >= 0
                parameters.wrappedValue.speakerCount = value > 0 ? value : nil
            })
    }

    private var prompt: Binding<String> {
        Binding(
            get: { parameters.wrappedValue.prompt ?? "" },
            set: { parameters.wrappedValue.prompt = $0.isEmpty ? nil : $0 })
    }

    private func publishes(_ key: String) -> Binding<Bool> {
        Binding(
            get: { parameters.wrappedValue.connectors.contains(key) },
            set: { on in
                parameters.wrappedValue.connectors.removeAll { $0 == key }
                if on { parameters.wrappedValue.connectors.append(key) }
            })
    }

    private var problem: String? {
        let current = parameters.wrappedValue
        let stt = settings.sttResolvers.resolvers.first { $0.recipeKey(role: .stt) == current.stt }
        return transcriptionProblem(
            isLocal: stt?.kind != .remote,
            options: TranscriptionOptions(language: current.language, diarize: current.detectSpeakers))
    }
}
