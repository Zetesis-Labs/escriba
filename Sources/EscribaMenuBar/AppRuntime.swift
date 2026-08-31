import Foundation
import EscribaModel
import EscribaCore
import EscribaKit
import EscribaStore
import EscribaWhisper
import Observation

@Observable
final class AppRuntime {
    private(set) var model: LibraryModel?
    private(set) var startupProblem: String?
    let settings: AppSettings

    @ObservationIgnored private var controllers: [DaemonController] = []
    @ObservationIgnored private var instanceLock: InstanceLock?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var settingsWatch: Task<Void, Never>?

    var symbolName: String {
        model?.status.symbolName ?? WatcherStatus.problem("").symbolName
    }

    var statusLabel: String {
        if let startupProblem { return "Problema: \(startupProblem)" }
        return model?.status.label ?? WatcherStatus.starting.label
    }

    init() {
        Log.mirrorToFile(Paths.logFile)
        Log.info("Escriba arrancando")
        LegacyMigration.run()
        AppSettings.adoptLegacyDefaults(from: UserDefaults(suiteName: "dev.ruben.jpr-transcribe"))
        settings = AppSettings()
        Notifier.requestAuthorization()
        start()
        watchSettings()
    }

    func wake() {
        controllers.forEach { $0.wake() }
    }

    private func start() {
        guard let lock = InstanceLock(path: Paths.lockFile) else {
            let holder = InstanceLock.holderDescription(path: Paths.lockFile)
            Log.error("ya hay \(holder) vigilando, esta copia no arranca")
            startupProblem = "ya hay otra copia vigilando"
            Notifier.problem(
                title: "Escriba ya esta abierto",
                detail: "Hay \(holder) vigilando. Esta copia no hara nada.")
            return
        }
        instanceLock = consume lock
        build()
    }

    private func rebuild() {
        Log.info("ajustes cambiados, reconstruyendo pipelines")
        startupProblem = nil
        build()
    }

    private func build() {
        stopPipelines()

        do {
            let store = try Store(root: Paths.defaultLibrary)
            let engine = WhisperKitEngine(language: settings.languageCode)

            let model = LibraryModel(store: store, reprocess: { [engine] url, count in
                try await engine.backend(diarize: true, speakerCount: count).transcribe(url)
            })
            model.startObserving()
            self.model = model

            do {
                try engine.backend().preflight()
            } catch {
                Log.error("\(error)")
                Notifier.problem(title: "Modelo de transcripcion no disponible", detail: "\(error)")
            }

            let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            events = Task { [settings] in
                for await event in stream {
                    model.apply(event)
                    if settings.notifyEveryNote || event.isProblem {
                        Notifier.notify(event)
                    }
                }
            }

            let ledger = try Ledger(path: Paths.defaultState)
            reconcileLibrary(store: store, ledger: ledger)
            controllers = sources(engine: engine).map { source, backend in
                let pipeline = Pipeline(
                    source: source,
                    ledger: ledger,
                    backend: backend,
                    sink: sink(for: store),
                    onEvent: { continuation.yield($0) }
                )
                let controller = DaemonController(pipeline: pipeline)
                controller.start()
                return controller
            }
            if controllers.isEmpty {
                Log.error("ninguna carpeta vigilada disponible")
                model.status = .problem("ninguna carpeta vigilada disponible")
            } else {
                model.status = .watching
            }
        } catch {
            startupProblem = "\(error)"
            Notifier.problem(title: "No se pudo arrancar", detail: "\(error)")
        }

        func sources(engine: WhisperKitEngine) -> [(RecordingSource, TranscriptionBackend)] {
            var result: [(RecordingSource, TranscriptionBackend)] = []
            var prefixes: Set<String> = []

            for folder in settings.watchedFolders {
                let folderRoot = URL(fileURLWithPath: folder.path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
                else {
                    Log.error(
                        "no encuentro \(folder.path); si existe, falta el Acceso total al disco")
                    Notifier.problem(
                        title: "Carpeta vigilada inaccesible", detail: folder.path)
                    continue
                }

                let diarize = folder.speakers != nil || settings.diarization != .off
                let backend = engine.backend(
                    diarize: diarize,
                    speakerCount: folder.speakers ?? settings.diarization.speakerCount)

                if folder.style == .justPressRecord {
                    result.append((justPressRecordSource(root: folderRoot), backend))
                    continue
                }

                var prefix = folderRoot.lastPathComponent
                var counter = 2
                while !prefixes.insert(prefix).inserted {
                    prefix = "\(folderRoot.lastPathComponent)-\(counter)"
                    counter += 1
                }
                result.append((
                    namespaced(
                        folderSource(
                            name: prefix, root: folderRoot, expectedSpeakers: folder.speakers),
                        prefix: prefix),
                    backend
                ))
            }
            return result
        }
    }

    private func reconcileLibrary(store: Store, ledger: Ledger) {
        Task {
            await offloaded {
                do {
                    try store.resetInterrupted()
                    store.adoptLedgerHistory(try ledger.doneRecords())
                } catch {
                    Log.error("no se pudo reconciliar la biblioteca con el ledger: \(error)")
                }
            }
        }
    }

    private func sink(for store: Store) -> Sink {
        let librarySink = store.sink(backend: WhisperKitBackend.name)
        guard settings.writeTxt else { return librarySink }
        return sinks(
            primary: sidecarTextSink(outputRoot: URL(fileURLWithPath: settings.txtFolderPath)),
            also: librarySink)
    }

    private func stopPipelines() {
        controllers.forEach { $0.stop() }
        controllers = []
        events?.cancel()
        events = nil
    }

    private func watchSettings() {
        settingsWatch = Task { [weak self] in
            guard let settings = self?.settings else { return }
            let changes = Observations {
                [
                    settings.language,
                    "\(settings.diarization.storageValue)",
                    "\(settings.writeTxt)",
                    settings.txtFolderPath,
                    settings.watchedFolders
                        .map { "\($0.path):\($0.speakers ?? 0)" }.joined(separator: ","),
                ].joined(separator: "|")
            }

            var initial = true
            for await _ in changes {
                if initial {
                    initial = false
                    continue
                }
                self?.rebuild()
            }
        }
    }
}
