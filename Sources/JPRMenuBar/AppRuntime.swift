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

    @ObservationIgnored private var controller: DaemonController?
    @ObservationIgnored private var instanceLock: InstanceLock?
    @ObservationIgnored private var events: Task<Void, Never>?

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
    }

    func wake() {
        controller?.wake()
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
            let model = LibraryModel(store: store, reprocess: { url, count in
                try WhisperKitBackend.make(diarize: true, speakerCount: count).transcribe(url)
            })
            model.startObserving()
            self.model = model

            let backend = WhisperKitBackend.make()
            do {
                try backend.preflight()
            } catch {
                Log.error("\(error)")
                Notifier.problem(title: "Modelo de transcripcion no disponible", detail: "\(error)")
            }

            let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            events = Task {
                for await event in stream {
                    model.apply(event)
                    Notifier.notify(event)
                }
            }

            let pipeline = Pipeline(
                source: justPressRecordSource(root: root),
                ledger: try Ledger(path: Paths.defaultState),
                backend: backend,
                sink: sinks(
                    primary: sidecarTextSink(outputRoot: Paths.defaultOutput),
                    also: store.sink(backend: backend.name)),
                onEvent: { continuation.yield($0) }
            )

            let controller = DaemonController(pipeline: pipeline)
            controller.start()
            self.controller = controller
            model.status = .watching
        } catch {
            startupProblem = "\(error)"
            Notifier.problem(title: "No se pudo arrancar", detail: "\(error)")
        }
    }
}
