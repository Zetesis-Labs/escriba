import EscribaCore
import EscribaModel
import EscribaOpenAI
import SwiftUI

struct ResolversPane: View {
    let resolvers: ResolversModel
    @Bindable var settings: AppSettings
    @State private var selected: UUID?
    @State private var removing: Resolver?

    private var role: ResolverRole { resolvers.role }

    var body: some View {
        ListDetailLayout(listWidth: 250) {
            VStack(spacing: 0) {
                List(resolvers.resolvers, selection: $selected) { resolver in
                    ResolverRow(resolver: resolver, problem: resolvers.problem(of: resolver))
                        .tag(resolver.id)
                }
                .listStyle(.inset)
                .onAppear { if selected == nil { selected = role.localID } }
                Divider()
                HStack(spacing: 0) {
                    Menu {
                        ForEach(remotePresets(for: role)) { preset in
                            Button(preset.name) { selected = resolvers.add(preset).id }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Añadir un servicio compatible con OpenAI")
                    Button {
                        removing = resolvers.resolvers.first { $0.id == selected }
                    } label: { Image(systemName: "minus") }
                    .disabled(selected == nil || selected == role.localID)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
        } detail: {
            if let id = selected, resolvers.resolvers.contains(where: { $0.id == id }) {
                ResolverEditor(editor: resolvers.editor(for: id))
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Sin resolutor elegido",
                    systemImage: role == .llm ? "sparkles" : "waveform.badge.mic",
                    description: Text("Elige uno de la lista o añade un servicio con +."))
            }
        }
        .navigationTitle(role.label)
        .confirmationDialog(
            "¿Quitar «\(removing?.name ?? "")»?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Quitar", role: .destructive) {
                if let removing { resolvers.remove(removing.id) }
                selected = role.localID
                removing = nil
            }
        } message: {
            Text("Se borra su clave. Las recetas que lo usaban pasan a \(role.localName).")
        }
    }
}

private struct ResolverRow: View {
    let resolver: Resolver
    let problem: String?

    var body: some View {
        HStack {
            Image(systemName: resolver.kind == .local ? "laptopcomputer" : "network")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading) {
                Text(resolver.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        if problem != nil, resolver.kind == .remote { return "Sin terminar de configurar" }
        switch resolver.kind {
        case .local: return "En este Mac"
        case .remote:
            let host = URL(string: resolver.baseURL)?.host() ?? resolver.baseURL
            return [host, resolver.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

private struct ResolverEditor: View {
    @Bindable var editor: ResolverModel

    private var role: ResolverRole { editor.role }

    var body: some View {
        Form {
            Section {
                if editor.isLocal {
                    LabeledContent("Nombre", value: editor.name)
                } else {
                    TextField("Nombre", text: $editor.name)
                }
                if let pending = editor.readiness {
                    Label(pending.prefix(1).uppercased() + pending.dropFirst(), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(role == .stt
                    ? "Cada receta elige con qué transcribir, en Recetas. La que no elige usa \(role.localName)."
                    : "Cada receta elige con qué resumir, en Recetas. La que no elige usa \(role.localName).")
            }

            if editor.isLocal {
                if role == .stt {
                    WhisperModelSection()
                    Section {
                        Text("Whisper transcribe en el propio Mac y es el único que detecta hablantes. El audio no sale de aquí.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("Apple Intelligence resume en el propio Mac: nada del audio ni del texto sale de aquí. Su ventana es pequeña, así que una nota larga se resume por trozos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                remoteSection
            }

            if role == .llm || !editor.isLocal {
                trialSection
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if editor.isDirty {
                    Text("Cambios sin guardar").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Descartar") { editor.discard() }
                    .disabled(!editor.isDirty)
                Button("Guardar") { editor.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.isDirty)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var remoteSection: some View {
        Section {
            Picker("Servicio", selection: presetBinding) {
                ForEach(remotePresets(for: role)) { preset in
                    Text(preset.name).tag(preset.name)
                }
            }
            TextField("URL de la API", text: $editor.baseURL, prompt: Text("https://api.openai.com/v1"))
            SecureField("Clave", text: $editor.key, prompt: Text("Vacía si el servicio no la pide"))
            HStack {
                TextField("Modelo", text: $editor.model, prompt: Text(role == .stt ? "whisper-1" : "Escribe o carga la lista"))
                if !editor.models.isEmpty {
                    Menu {
                        ForEach(editor.models, id: \.self) { model in
                            Button(model) { editor.model = model }
                        }
                    } label: {
                        Text("\(editor.models.count) modelos")
                    }
                    .fixedSize()
                }
                Button("Cargar modelos") { Task { await editor.loadModels() } }
                    .disabled(remoteURLProblem(editor.baseURL) != nil || editor.phase.isWorking)
            }
        } header: {
            Text("Servicio compatible con OpenAI")
        } footer: {
            Text(role == .stt
                ? "El audio de cada nota sale del Mac hacia este servicio. Con un servicio remoto no se detectan hablantes. OpenAI y Groq admiten audios de hasta 25 MB."
                : "El texto de cada nota sale del Mac hacia este servicio. Sirve cualquier API compatible con OpenAI: OpenAI, OpenRouter, Groq o, en tu red, LM Studio y Ollama.")
        }
    }

    private var trialSection: some View {
        Section {
            HStack {
                Button(role == .llm ? "Resumir la nota de ejemplo" : "Transcribir un audio de prueba") {
                    Task { await editor.tryIt() }
                }
                .disabled(editor.readiness != nil || editor.phase.isWorking)
                if editor.phase.isWorking { ProgressView().controlSize(.small) }
            }
            if let problem = editor.phase.problem {
                Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            switch editor.trial {
            case .digest(let digest):
                VStack(alignment: .leading, spacing: 6) {
                    Text(digest.title).font(.headline)
                    Text(digest.summary)
                    if !digest.tags.isEmpty {
                        Text(digest.tags.map { "#\($0)" }.joined(separator: " "))
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            case .transcript(let text):
                Label(
                    text.isEmpty ? "El servicio acepta el audio y responde." : "El servicio responde: «\(text)»",
                    systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Probar")
        } footer: {
            Text(role == .llm
                ? "Resume una conversación corta de ejemplo con lo que hay escrito, antes de guardar."
                : "Manda un segundo de silencio con lo que hay escrito, antes de guardar.")
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: {
                remotePresets(for: role).first { $0.baseURL == editor.baseURL && !$0.baseURL.isEmpty }?.name
                    ?? "Otro servicio compatible"
            },
            set: { name in
                guard let preset = remotePresets(for: role).first(where: { $0.name == name }) else { return }
                editor.apply(preset)
            })
    }
}

struct ResolverChoiceForm: View {
    @Binding var choice: ResolverChoice
    let settings: AppSettings
    let origin: ResolverChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ResolverRole.allCases, id: \.self) { role in
                VStack(alignment: .leading, spacing: 6) {
                    Text(role == .stt ? "Transcribir con" : "Resumir con").font(.headline)
                    Picker(role == .stt ? "Transcribir con" : "Resumir con", selection: selection(role)) {
                        Text("Por defecto (\(settings.resolvers(role).resolver(origin[role]).name))")
                            .tag(UUID?.none)
                        ForEach(settings.resolvers(role).resolvers) { resolver in
                            Text(resolver.name).tag(UUID?.some(resolver.id))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            Text("Solo para la próxima grabación o los próximos audios; luego vuelve a lo de siempre.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func selection(_ role: ResolverRole) -> Binding<UUID?> {
        Binding(
            get: { choice[role].flatMap { settings.resolvers(role).contains($0) ? $0 : nil } },
            set: { choice[role] = $0 })
    }
}

func resolverChoiceLabel(_ choice: ResolverChoice, settings: AppSettings) -> String? {
    guard !choice.isEmpty else { return nil }
    return ResolverRole.allCases.compactMap { role in
        choice[role].map { settings.resolvers(role).resolver($0).name }
    }.joined(separator: " · ")
}
