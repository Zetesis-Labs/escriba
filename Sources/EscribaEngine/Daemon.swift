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
    private let watch: FolderWatcher
    private let waker = WakeSignal()
    private var loop: Task<Void, Never>?
    private var watches: [FolderWatch] = []

    public init(
        pipeline: Pipeline,
        watch: @escaping FolderWatcher = noWatcher,
        reconcileInterval: TimeInterval = reconcileInterval,
        retryInterval: TimeInterval = retryInterval,
        debounce: TimeInterval = debounce
    ) {
        self.pipeline = pipeline
        self.watch = watch
        self.reconcileInterval = reconcileInterval
        self.retryInterval = retryInterval
        self.debounce = debounce
    }

    public func start() {
        watches = pipeline.source.locations.map { location in
            watch(location) { [waker] in
                Log.debug("evento de fichero")
                Task { await waker.signal() }
            }
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
        watches.forEach { $0.stop() }
        watches = []
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
        do {
            return try await pipeline.runOnce()
        } catch {
            Log.error("ciclo fallido, se continua: \(error)")
            return PassOutcome(processed: 0, deferred: 0)
        }
    }
}
