import EscribaCore
import EscribaModel
import EscribaStore
import SwiftUI

struct PeoplePane: View {
    let people: PeopleModel?

    var body: some View {
        if let people {
            PeopleList(people: people)
        } else {
            ContentUnavailableView(
                "Personas no disponibles", systemImage: "person.2",
                description: Text("La biblioteca no ha arrancado."))
        }
    }
}

private struct PeopleList: View {
    @Bindable var people: PeopleModel
    @State private var selected: String?
    @State private var registering: String?
    @State private var removing: String?
    @State private var problem: String?

    var body: some View {
        ListDetailLayout(listWidth: 250) {
            VStack(spacing: 0) {
                List(people.people, selection: $selected) { person in
                    VStack(alignment: .leading) {
                        Text(person.name)
                        Text(voiceCount(person.voices.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(person.name)
                }
                .listStyle(.inset)
                Divider()
                HStack(spacing: 0) {
                    Button {
                        registering = ""
                    } label: { ListBarIcon(systemName: "plus") }
                    .help("Registrar la voz de alguien")
                    Button {
                        removing = selected
                    } label: { ListBarIcon(systemName: "minus") }
                    .disabled(selected == nil)
                    .help("Olvidar a esta persona y sus huellas")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
        } detail: {
            if let person = people.people.first(where: { $0.name == selected }) {
                PersonDetail(
                    person: person, others: people.people.map(\.name).filter { $0 != person.name },
                    onRename: { newName in run { try await people.rename(person.name, to: newName); selected = newName } },
                    onRemoveVoice: { id in run { try await people.removeVoice(id) } },
                    onRegister: { registering = person.name })
                    .id(person.name)
            } else {
                ContentUnavailableView(
                    "Sin persona elegida", systemImage: "person.2",
                    description: Text(
                        "Una persona aparece al renombrar a un hablante en una grabación (Hablantes → Renombrar…) o al registrar su voz con +. Escriba la reconoce en las grabaciones siguientes."))
            }
        }
        .navigationTitle("Personas")
        .task { run { try people.reload() } }
        .sheet(item: Binding(get: { registering.map(SampleTarget.init) }, set: { registering = $0?.name })) { target in
            VoiceSampleSheet(people: people, name: target.name) { registered in
                registering = nil
                if let registered { selected = registered }
            }
        }
        .confirmationDialog(
            "¿Olvidar a «\(removing ?? "")»?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Olvidar", role: .destructive) {
                if let name = removing { run { try await people.remove(name) } }
                selected = nil
                removing = nil
            }
        } message: {
            Text("Se borran sus huellas. Las grabaciones donde sale conservan el nombre.")
        }
        .alert(
            "No se pudo",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("Vale") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                problem = "\(error)"
            }
        }
    }
}

private struct SampleTarget: Identifiable {
    let name: String
    var id: String { name }
}

private func voiceCount(_ count: Int) -> String {
    count == 1 ? "1 huella" : "\(count) huellas"
}

private struct PersonDetail: View {
    let person: Person
    let others: [String]
    let onRename: (String) -> Void
    let onRemoveVoice: (Int64) -> Void
    let onRegister: () -> Void
    @State private var name: String

    init(
        person: Person, others: [String], onRename: @escaping (String) -> Void,
        onRemoveVoice: @escaping (Int64) -> Void, onRegister: @escaping () -> Void
    ) {
        self.person = person
        self.others = others
        self.onRename = onRename
        self.onRemoveVoice = onRemoveVoice
        self.onRegister = onRegister
        _name = State(initialValue: person.name)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $name)
                    .onSubmit(rename)
                if !others.isEmpty {
                    Menu("Juntar con…") {
                        ForEach(others, id: \.self) { other in
                            Button(other) { onRename(other) }
                        }
                    }
                }
            } footer: {
                Text("Pulsa Intro para cambiar el nombre. Si ya hay alguien con ese nombre, se juntan sus huellas.")
            }
            Section {
                ForEach(person.voices) { voice in
                    HStack {
                        Image(systemName: voice.source == PeopleModel.sampleSource ? "mic" : "waveform")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading) {
                            Text(voice.source == PeopleModel.sampleSource ? "Muestra de voz" : voice.source)
                            Text(voice.addedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            onRemoveVoice(voice.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Quitar esta huella")
                    }
                }
                Button("Registrar su voz…", action: onRegister)
            } header: {
                Text("Huellas")
            } footer: {
                Text(
                    "Cada vez que renombras a alguien en una grabación o registras su voz se añade una huella, y Escriba compara con la más cercana. Las huellas no salen de este Mac.")
            }
        }
        .formStyle(.grouped)
    }

    private func rename() {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted != person.name else { return }
        onRename(wanted)
    }
}

private struct VoiceSampleSheet: View {
    @Bindable var people: PeopleModel
    @State var name: String
    let onFinish: (String?) -> Void
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Registrar una voz")
                .font(.headline)
            TextField("Nombre", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)
            Text(
                "Pulsa Grabar y habla con normalidad durante un minuto, por ejemplo leyendo un texto en voz alta. Hacen falta al menos \(Int(PeopleModel.minimumSampleSpeech)) segundos de voz. El audio se borra al terminar: solo queda su huella, que no sale de este Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) {
                    people.cancelSample()
                    people.dismissProblem()
                    onFinish(nil)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isAnalyzing)
                primaryButton
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private var status: some View {
        switch people.sample {
        case .recording:
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(durationClock(context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
            }
        case .requesting:
            ProgressView("Pidiendo permiso para el micrófono…")
                .controlSize(.small)
        case .analyzing:
            ProgressView("Sacando la huella…")
                .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if case .recording = people.sample {
            Button("Terminar") {
                let person = name.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await people.stopSample()
                    if people.sample == .idle { onFinish(person) }
                }
            }
        } else {
            Button("Grabar") {
                startedAt = Date()
                Task { await people.startSample(for: name) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
        }
    }

    private var isAnalyzing: Bool {
        if case .analyzing = people.sample { return true }
        return false
    }

    private var isBusy: Bool {
        switch people.sample {
        case .requesting, .recording, .analyzing: true
        case .idle, .failed: false
        }
    }
}
