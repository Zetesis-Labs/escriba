import Foundation
import JavaScriptCore
import EscribaCore
import EscribaEngine

private let connectorExecutor = RunLoopExecutor(name: "dev.ruben.escriba.conectores")

actor ConnectorRun {
    nonisolated var unownedExecutor: UnownedSerialExecutor { connectorExecutor.asUnownedSerialExecutor() }
    private let program: ConnectorProgram
    private let bridge: ConnectorBridge
    private let timeLimit: Double
    private let wallTimeLimit: Double
    private let inspecting: Bool
    private var context: JSContext?
    private var prelude: JSValue?
    private var pending: [Int: Task<Void, Never>] = [:]
    private var timers: [Int: Timer] = [:]
    private var deadline: Timer?
    private var errors: [Int: any Error] = [:]
    private var nextID = 0
    private var continuation: CheckedContinuation<String, any Error>?
    private var finished = false
    private var exception: String?

    init(program: ConnectorProgram, bridge: ConnectorBridge, timeLimit: Double, wallTimeLimit: Double, inspecting: Bool = false) {
        self.program = program
        self.bridge = bridge
        self.timeLimit = timeLimit
        self.wallTimeLimit = wallTimeLimit
        self.inspecting = inspecting
    }

    func execute(_ request: String) async throws -> String {
        guard !finished else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start(request)
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func start(_ request: String) {
        guard let limit = executionTimeLimit(), let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            finish(.failure(RecipeError.unavailable("JavaScriptCore no arranca")))
            return
        }
        self.context = context
        limit(JSContextGetGroup(context.jsGlobalContextRef), timeLimit, { _, _ in true }, nil)
        context.exceptionHandler = { [weak self] _, value in
            let message = describe(value)
            self?.assumeIsolated { $0.exception = message }
        }
        let rpc: @convention(block) (String) -> Int = { [weak self] text in
            self?.assumeIsolated { $0.call(text) } ?? 0
        }
        let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, milliseconds in
            self?.assumeIsolated { $0.schedule(id, milliseconds) }
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in
            self?.assumeIsolated { $0.timers.removeValue(forKey: id)?.invalidate() }
        }
        context.setObject(rpc, forKeyedSubscript: "__connectorCall" as NSString)
        context.setObject(schedule, forKeyedSubscript: "__connectorTimer" as NSString)
        context.setObject(clear, forKeyedSubscript: "__connectorClearTimer" as NSString)
        prelude = context.evaluateScript(connectorPreludeSource)
        context.evaluateScript(program.source)
        if checkException() { return }
        let done: @convention(block) (String) -> Void = { [weak self] result in
            self?.assumeIsolated { $0.finish(.success(result)) }
        }
        let failed: @convention(block) (String, Int) -> Void = { [weak self] message, token in
            self?.assumeIsolated { run in
                run.finish(.failure(run.errors[token] ?? RecipeError.failed(message)))
            }
        }
        let deadline = Timer(timeInterval: max(0.001, wallTimeLimit), repeats: false) { [weak self] _ in
            self?.assumeIsolated { $0.finish(.failure(RecipeError.timedOut($0.wallTimeLimit))) }
        }
        self.deadline = deadline
        RunLoop.current.add(deadline, forMode: .default)
        let entered = ContinuousClock.now
        prelude?.invokeMethod(inspecting ? "inspect" : "run", withArguments: [request, JSValue(object: done, in: context) as Any, JSValue(object: failed, in: context) as Any])
        afterEntry(entered)
    }

    private func call(_ request: String) -> Int {
        nextID += 1
        let id = nextID
        guard !finished else { return id }
        let bridge = bridge
        pending[id] = Task { [weak self] in
            let result: Result<String, any Error>
            do { result = .success(try await bridge.call(request)) }
            catch { result = .failure(error) }
            await self?.settle(id, result)
        }
        return id
    }

    private func settle(_ id: Int, _ result: Result<String, any Error>) {
        guard !finished, pending.removeValue(forKey: id) != nil else { return }
        let entered = ContinuousClock.now
        switch result {
        case .success(let text): prelude?.invokeMethod("resolve", withArguments: [id, text])
        case .failure(let error):
            errors[id] = error
            prelude?.invokeMethod("reject", withArguments: [id, String(describing: error)])
        }
        afterEntry(entered)
    }

    private func schedule(_ id: Int, _ milliseconds: Double) {
        guard !finished, milliseconds.isFinite, timers.count < 1024 else { return }
        let timer = Timer(timeInterval: max(0.001, milliseconds / 1000), repeats: false) { [weak self] _ in
            self?.assumeIsolated { run in
                run.timers[id] = nil
                let entered = ContinuousClock.now
                run.prelude?.invokeMethod("fire", withArguments: [id])
                run.afterEntry(entered)
            }
        }
        timers[id] = timer
        RunLoop.current.add(timer, forMode: .default)
    }

    private func afterEntry(_ entered: ContinuousClock.Instant) {
        guard !finished, !checkException() else { return }
        if ContinuousClock.now - entered >= .seconds(timeLimit) {
            finish(.failure(RecipeError.timedOut(timeLimit)))
        }
    }

    private func checkException() -> Bool {
        guard let exception else { return false }
        self.exception = nil
        finish(.failure(exception.contains("terminated") ? RecipeError.timedOut(timeLimit) : RecipeError.failed(exception)))
        return true
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !finished else { return }
        finished = true
        deadline?.invalidate()
        deadline = nil
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        continuation?.resume(with: result)
        continuation = nil
        prelude = nil
        context = nil
    }
}
