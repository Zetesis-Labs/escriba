import Foundation
import JPRApp
import JPRCore
import JPRKit
import JPRStore
import JPRWhisperKit
import Observation

@Observable
final class AppRuntime {
    private(set) var model: LibraryModel?
    private(set) var startupProblem: String?
    let settings = AppSettings()

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
        Log.info("JPR Transcribe arrancando")
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
                title: "JPR Transcribe ya esta abierto",
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

        let root = Paths.defaultRoot
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            Log.error(
                "no encuentro \(root.path(percentEncoded: false)); si existe, falta el Acceso total al disco")
            startupProblem = "no encuentro la carpeta de Just Press Record"
            Notifier.problem(
                title: "Just Press Record no encontrado",
                detail: "No existe \(root.path(percentEncoded: false))")
            return
        }

        do {
            let store = try Store(root: Paths.defaultLibrary)
            let engine = WhisperKitEngine(language: settings.languageCode)

            let model = LibraryModel(store: store, reprocess: { [engine] url, count in
                try engine.backend(diarize: true, speakerCount: count).transcribe(url)
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
            controllers = sources(jprRoot: root, engine: engine).map { source, backend in
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
            model.status = .watching
        } catch {
            startupProblem = "\(error)"
            Notifier.problem(title: "No se pudo arrancar", detail: "\(error)")
        }

        func sources(
            jprRoot: URL, engine: WhisperKitEngine
        ) -> [(RecordingSource, TranscriptionBackend)] {
            var result: [(RecordingSource, TranscriptionBackend)] = [
                (
                    justPressRecordSource(root: jprRoot),
                    engine.backend(
                        diarize: settings.diarization != .off,
                        speakerCount: settings.diarization.speakerCount)
                )
            ]

            var prefixes: Set<String> = []
            for folder in settings.watchedFolders {
                let folderRoot = URL(fileURLWithPath: folder.path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
                else {
                    Log.error("carpeta vigilada inexistente, se ignora: \(folder.path)")
                    continue
                }

                var prefix = folderRoot.lastPathComponent
                var counter = 2
                while !prefixes.insert(prefix).inserted {
                    prefix = "\(folderRoot.lastPathComponent)-\(counter)"
                    counter += 1
                }

                let diarize = folder.speakers != nil || settings.diarization != .off
                result.append((
                    namespaced(
                        folderSource(
                            name: prefix, root: folderRoot, expectedSpeakers: folder.speakers),
                        prefix: prefix),
                    engine.backend(
                        diarize: diarize,
                        speakerCount: folder.speakers ?? settings.diarization.speakerCount)
                ))
            }
            return result
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
