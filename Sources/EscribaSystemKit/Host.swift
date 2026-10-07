import Foundation
import EscribaCore
import EscribaEngine

extension Pipeline {
    public init(
        source: RecordingSource,
        ledger: Ledger,
        backend: TranscriptionBackend,
        sink: @escaping Sink,
        settleSeconds: TimeInterval = 15,
        materializeTimeout: TimeInterval = 300,
        enrich: Enricher? = nil,
        memory: NoteMemory? = nil,
        onEvent: EventHandler? = nil
    ) {
        self.init(
            source: source,
            ledger: ledger.port,
            backend: backend,
            sink: sink,
            readiness: fileReadiness(settleSeconds: settleSeconds, materializeTimeout: materializeTimeout),
            enrich: enrich,
            memory: memory,
            onEvent: onEvent)
    }
}

public func fileReadiness(settleSeconds: TimeInterval, materializeTimeout: TimeInterval) -> ReadinessProbe {
    { recording in
        await offloaded {
            guard var probe = FileSystem.probe(recording.url) else { return .empty }

            var state = classify(probe: probe, previous: nil, settleSeconds: settleSeconds)
            guard state == .dataless else { return state }

            Log.info("\(recording.key) esta en la nube, forzando descarga")
            FileSystem.requestMaterialization(recording.url, timeout: materializeTimeout)

            guard let refreshed = FileSystem.probe(recording.url) else { return .empty }
            probe = refreshed
            state = classify(probe: probe, previous: nil, settleSeconds: settleSeconds)
            return state
        }
    }
}

extension DaemonController {
    public convenience init(
        pipeline: Pipeline,
        reconcileInterval: TimeInterval = reconcileInterval,
        retryInterval: TimeInterval = retryInterval,
        debounce: TimeInterval = debounce
    ) {
        self.init(
            pipeline: pipeline,
            watch: systemFolderWatcher,
            reconcileInterval: reconcileInterval,
            retryInterval: retryInterval,
            debounce: debounce)
    }
}

public let systemFolderWatcher: FolderWatcher = { root, onChange in
    #if os(macOS)
    let watcher = DirectoryWatcher(root: root, onRelevantChange: onChange)
    watcher.start()
    return FolderWatch(stop: { watcher.stop() })
    #else
    let poller = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            onChange()
        }
    }
    return FolderWatch(stop: { poller.cancel() })
    #endif
}

public func runUntilTerminated(_ controller: DaemonController) {
    controller.start()

    let stopped = DispatchSemaphore(value: 0)
    var sources: [DispatchSourceSignal] = []
    for code in [SIGTERM, SIGINT] {
        signal(code, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
        source.setEventHandler {
            Log.info("parando")
            controller.stop()
            stopped.signal()
        }
        source.resume()
        sources.append(source)
    }
    stopped.wait()
    withExtendedLifetime(sources) {}
}
