import JPRApp
import JPRWhisperKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionTab(settings: settings)
                .tabItem { Label("Transcripcion", systemImage: "waveform") }
            FoldersTab(settings: settings)
                .tabItem { Label("Carpetas", systemImage: "folder.badge.plus") }
            ModelTab()
                .tabItem { Label("Modelo", systemImage: "internaldrive") }
        }
        .frame(width: 500)
    }
}

private struct GeneralTab: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Arrancar al iniciar sesion", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("Notificar cada transcripcion", isOn: $settings.notifyEveryNote)
            Text("Los problemas se notifican siempre.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Idioma", selection: $settings.language) {
                Text("Espanol").tag("es")
                Text("English").tag("en")
                Text("Detectar en cada nota").tag("auto")
            }

            Picker("Detectar hablantes", selection: diarization) {
                Text("No").tag(-1)
                Text("Automatico").tag(0)
                ForEach(2...4, id: \.self) { count in
                    Text("\(count) hablantes").tag(count)
                }
            }
            Text("Detectar hablantes cuesta unos segundos mas por nota.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Copia en texto plano") {
                Toggle("Escribir tambien un .txt", isOn: $settings.writeTxt)
                if settings.writeTxt {
                    LabeledContent("Carpeta") {
                        HStack {
                            Text(abbreviated(settings.txtFolderPath))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Cambiar…") {
                                if let path = chooseFolder() { settings.txtFolderPath = path }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var diarization: Binding<Int> {
        Binding(
            get: { settings.diarization.storageValue },
            set: { settings.diarization = Diarization(storageValue: $0) })
    }
}

private struct FoldersTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if settings.watchedFolders.isEmpty {
                    Text("Ninguna carpeta extra. Solo se vigila Just Press Record.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.watchedFolders) { $folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                            Text(abbreviated(folder.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Picker("", selection: $folder.speakers) {
                            Text("Segun ajuste global").tag(Int?.none)
                            ForEach(2...4, id: \.self) { count in
                                Text("\(count) hablantes").tag(Int?.some(count))
                            }
                        }
                        .frame(width: 170)
                        Button(role: .destructive) {
                            settings.watchedFolders.removeAll { $0.path == folder.path }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Carpetas vigiladas")
            } footer: {
                Text("Cualquier audio que caiga en ellas se transcribe solo. Las claves llevan el nombre de la carpeta como prefijo.")
            }

            Button("Anadir carpeta…") {
                guard let path = chooseFolder(),
                    !settings.watchedFolders.contains(where: { $0.path == path })
                else { return }
                settings.watchedFolders.append(WatchedFolder(path: path))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelTab: View {
    @State private var installed = WhisperKitBackend.installedModelFolder()
    @State private var sizeOnDisk: String?
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        Form {
            LabeledContent("Modelo", value: WhisperKitBackend.defaultVariant)

            if installed != nil {
                LabeledContent("Estado", value: "descargado\(sizeOnDisk.map { " · \($0)" } ?? "")")
                Button("Borrar del disco", role: .destructive) { delete() }
                Text("Sin el modelo no se transcribe nada hasta volver a descargarlo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let progress {
                ProgressView("Descargando…", value: progress)
            } else {
                LabeledContent("Estado", value: "no descargado")
                Button("Descargar (unos 3 GB)") { download() }
            }

            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    private func refresh() {
        installed = WhisperKitBackend.installedModelFolder()
        Task { await measure() }
    }

    private func measure() async {
        guard let installed else { return }
        sizeOnDisk = await Task.detached { directorySize(installed) }.value
    }

    private func download() {
        progress = 0
        failure = nil
        Task {
            do {
                try await Task.detached {
                    try WhisperKitBackend.downloadModel { fraction in
                        Task { @MainActor in progress = fraction }
                    }
                }.value
            } catch {
                failure = "\(error)"
            }
            progress = nil
            refresh()
        }
    }

    private func delete() {
        try? FileManager.default.removeItem(at: WhisperKitBackend.defaultModelsRoot)
        sizeOnDisk = nil
        refresh()
    }
}

private func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path(percentEncoded: false)
}

private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

private nonisolated func directorySize(_ folder: URL) -> String {
    let walker = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.fileSizeKey])
    var total = 0
    while case let url as URL = walker?.nextObject() {
        total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
}
