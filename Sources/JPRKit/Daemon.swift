import Foundation
import JPRCore

public final class DaemonController: @unchecked Sendable {
    public static let reconcileInterval: TimeInterval = 300
    public static let retryInterval: TimeInterval = 10
    public static let debounce: TimeInterval = 3

    private let pipeline: Pipeline
    private let reconcileInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let waker = Waker()
    private let stopping = Waker()
    private var watchers: [DirectoryWatcher] = []
    private var thread: Thread?

    public init(
        pipeline: Pipeline,
        reconcileInterval: TimeInterval = reconcileInterval,
        retryInterval: TimeInterval = retryInterval
    ) {
        self.pipeline = pipeline
        self.reconcileInterval = reconcileInterval
        self.retryInterval = retryInterval
    }

    public func start() {
        watchers = pipeline.source.locations.map { location in
            let watcher = DirectoryWatcher(root: location) { [waker] in
                Log.debug("evento de fichero")
                waker.signal()
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

        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "dev.ruben.jpr-transcribe.loop"
        thread.start()
        self.thread = thread
    }

    public func wake() {
        waker.signal()
    }

    public func stop() {
        stopping.signal()
        waker.signal()
        watchers.forEach { $0.stop() }
        watchers = []
    }

    public func runBlocking() {
        start()
        installSignalHandlers()
        while !stopping.isSignalled {
            Thread.sleep(forTimeInterval: 0.5)
        }
        stop()
    }

    private func loop() {
        while !stopping.isSignalled {
            var outcome = PassOutcome(processed: 0, deferred: 0)
            do {
                outcome = try pipeline.runOnce()
            } catch {
                Log.error("ciclo fallido, se continua: \(error)")
            }

            let interval = nextWakeInterval(
                after: outcome, retryInterval: retryInterval, reconcileInterval: reconcileInterval)

            let woken = waker.wait(timeout: interval)
            if woken && !stopping.isSignalled {
                Thread.sleep(forTimeInterval: Self.debounce)
            }
        }
    }

    private func installSignalHandlers() {
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
            source.setEventHandler { [weak self] in
                Log.info("parando")
                self?.stopping.signal()
                self?.waker.signal()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []
}

final class Waker: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = false
    private(set) var isSignalled = false

    func signal() {
        condition.lock()
        pending = true
        isSignalled = true
        condition.signal()
        condition.unlock()
    }

    @discardableResult
    func wait(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer {
            pending = false
            condition.unlock()
        }

        if pending { return true }
        return condition.wait(until: Date().addingTimeInterval(timeout))
    }
}
