import Foundation
import EscribaCore

public final class DaemonController: @unchecked Sendable {
    public static let reconcileInterval: TimeInterval = 300
    public static let retryInterval: TimeInterval = 10
    public static let debounce: TimeInterval = 3

    private let pipeline: Pipeline
    private let reconcileInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let debounce: TimeInterval
    private let waker = WakeSignal()
    private let passQueue = DispatchQueue(label: "dev.ruben.escriba.pass")
    private var loop: Task<Void, Never>?
    private var watchers: [DirectoryWatcher] = []
    private var signalSources: [DispatchSourceSignal] = []

    public init(
        pipeline: Pipeline,
        reconcileInterval: TimeInterval = reconcileInterval,
        retryInterval: TimeInterval = retryInterval,
        debounce: TimeInterval = debounce
    ) {
        self.pipeline = pipeline
        self.reconcileInterval = reconcileInterval
        self.retryInterval = retryInterval
        self.debounce = debounce
    }

    public func start() {
        watchers = pipeline.source.locations.map { location in
            let watcher = DirectoryWatcher(root: location) { [waker] in
                Log.debug("evento de fichero")
                Task { await waker.signal() }
            }
            watcher.start()
            return watcher
        }

        let paths = pipeline.source.locations
            .map { $0.path(percentEncoded: false) }
            .joined(separator: ", ")
        Log.info(
            "vigilando \(paths) [\(pipeline.source.name)] (reconciliacion cada \(Int(reconcileInterval))s)"
        )

        loop = Task { await run() }
    }

    public func wake() {
        Task { [waker] in await waker.signal() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        watchers.forEach { $0.stop() }
        watchers = []
    }

    public func runBlocking() {
        start()

        let stopped = DispatchSemaphore(value: 0)
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
            source.setEventHandler { [weak self] in
                Log.info("parando")
                self?.stop()
                stopped.signal()
            }
            source.resume()
            signalSources.append(source)
        }
        stopped.wait()
    }

    private func run() async {
        while !Task.isCancelled {
            let outcome = await pass()
            let interval = nextWakeInterval(
                after: outcome, retryInterval: retryInterval, reconcileInterval: reconcileInterval)

            let woken = await waker.wait(upTo: interval)
            if woken, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(debounce))
            }
        }
    }

    private func pass() async -> PassOutcome {
        let pipeline = pipeline
        return await withCheckedContinuation { continuation in
            passQueue.async {
                do {
                    continuation.resume(returning: try pipeline.runOnce())
                } catch {
                    Log.error("ciclo fallido, se continua: \(error)")
                    continuation.resume(returning: PassOutcome(processed: 0, deferred: 0))
                }
            }
        }
    }
}
