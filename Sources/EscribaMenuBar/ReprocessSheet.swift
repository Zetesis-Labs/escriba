import EscribaCore
import EscribaModel
import SwiftUI

struct ReprocessSheet: View {
    @State private var language: String
    @State private var diarize: Bool
    @State private var speakerCount: Int
    @State private var resolvers: ResolverChoice
    let settings: AppSettings
    let origin: ResolverChoice
    let onRun: (TranscriptionOptions, ResolverChoice) -> Void
    let onCancel: () -> Void

    init(
        options: TranscriptionOptions,
        resolvers: ResolverChoice,
        origin: ResolverChoice,
        settings: AppSettings,
        onRun: @escaping (TranscriptionOptions, ResolverChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _language = State(initialValue: options.language ?? "auto")
        _diarize = State(initialValue: options.diarize)
        _speakerCount = State(initialValue: options.speakerCount ?? 0)
        _resolvers = State(initialValue: resolvers)
        self.settings = settings
        self.origin = origin
        self.onRun = onRun
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reprocesar con otros criterios")
                .font(.headline)
            Form {
                ResolverPicker(
                    title: "Transcribir con", role: .stt, choice: $resolvers, settings: settings,
                    fallback: settings.resolvers(.stt).resolver(origin.stt), fallbackLabel: "Su origen")
                ResolverPicker(
                    title: "Resumir con", role: .llm, choice: $resolvers, settings: settings,
                    fallback: settings.resolvers(.llm).resolver(origin.llm), fallbackLabel: "Su origen")
                Picker("Idioma", selection: $language) {
                    Text("Detectar").tag("auto")
                    Text("Español").tag("es")
                    Text("English").tag("en")
                }
                Toggle("Detectar hablantes", isOn: $diarize)
                if diarize {
                    Picker("Número de hablantes", selection: $speakerCount) {
                        Text("Automático").tag(0)
                        ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
                    }
                    if settings.resolvers(.stt).resolver(resolvers.stt ?? origin.stt).kind == .remote {
                        Text("Con un servicio remoto no se detectan hablantes.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            Text("El resultado se guarda como una versión nueva; la original se conserva y puedes volver a ella. Lo que elijas para transcribir y resumir se queda para esta grabación.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Reprocesar") { onRun(options, resolvers) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private var options: TranscriptionOptions {
        TranscriptionOptions(
            language: language == "auto" ? nil : language,
            diarize: diarize,
            speakerCount: speakerCount == 0 ? nil : speakerCount)
    }
}
