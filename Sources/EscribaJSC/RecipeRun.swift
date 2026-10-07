import Dispatch
import Foundation
import JavaScriptCore
import EscribaCore
import EscribaEngine

actor RecipeRun {
    private let queue = DispatchSerialQueue(label: "dev.ruben.escriba.receta")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let package: RecipePackage
    private let bridge: RecipeBridge
    private let timeLimit: Double

    private var context: JSContext?
    private var prelude: JSValue?
    private var pending: Set<Int> = []
    private var swiftErrors: [Int: any Error] = [:]
    private var nextId = 0
    private var exception: String?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false

    init(package: RecipePackage, bridge: RecipeBridge, timeLimit: Double) {
        self.package = package
        self.bridge = bridge
        self.timeLimit = timeLimit
    }

    func execute() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    private func start() {
        guard let setLimit = executionTimeLimit(), let context = JSContext(virtualMachine: JSVirtualMachine())
        else {
            finish(.failure(RecipeError.unavailable("JavaScriptCore no arranca")))
            return
        }
        self.context = context
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), timeLimit, { _, _ in true }, nil)
        context.exceptionHandler = { [weak self] _, exception in
            let message = describe(exception)
            self?.assumeIsolated { $0.exception = message }
        }

        context.setObject(puente(in: context), forKeyedSubscript: "__puente" as NSString)
        prelude = context.evaluateScript(preludeSource, withSourceURL: URL(string: "escriba://preludio.js"))
        if let failure = takeException() {
            finish(.failure(RecipeError.unavailable("el preludio no carga: \(failure)")))
            return
        }

        context.evaluateScript(package.source, withSourceURL: URL(string: "receta://\(package.key).js"))
        if let failure = takeException() {
            finish(.failure(RecipeError.invalidPackage(failure)))
            return
        }
        if let problem = prelude?.objectForKeyedSubscript("validar").call(withArguments: []).toString(),
            !problem.isEmpty
        {
            finish(.failure(RecipeError.invalidPackage(problem)))
            return
        }

        let audio: String
        do {
            audio = try recipeJSON(bridge.audio)
        } catch {
            finish(.failure(error))
            return
        }
        let done: @convention(block) () -> Void = { [weak self] in
            self?.assumeIsolated { $0.finish(.success(())) }
        }
        let failed: @convention(block) (JSValue?) -> Void = { [weak self] reason in
            let token = errorToken(reason)
            let message = describe(reason)
            self?.assumeIsolated { run in run.finish(.failure(run.swiftError(token: token, message: message))) }
        }
        let entered = ContinuousClock.now
        prelude?.objectForKeyedSubscript("ejecutar").call(withArguments: [
            audio, JSValue(object: done, in: context) as Any, JSValue(object: failed, in: context) as Any,
        ])
        afterEntry(since: entered)
    }

    private func puente(in context: JSContext) -> JSValue {
        let puente = JSValue(newObjectIn: context)!
        let bridge = bridge
        puente.setObject(try? recipeJSON(bridge.stts), forKeyedSubscript: "stts" as NSString)
        puente.setObject(try? recipeJSON(bridge.llms), forKeyedSubscript: "llms" as NSString)
        puente.setObject(try? recipeJSON(bridge.connectors), forKeyedSubscript: "conectores" as NSString)
        let transcribe: @convention(block) (String) -> Int = { [weak self] options in
            self?.assumeIsolated { run in
                run.ask {
                    let request = try decodeOptions(RecipeTranscription.self, options, for: "transcribir")
                    return try recipeJSON(try await bridge.transcribe(request))
                }
            } ?? 0
        }
        puente.setObject(transcribe, forKeyedSubscript: "transcribir" as NSString)
        let summarize: @convention(block) (String) -> Int = { [weak self] options in
            self?.assumeIsolated { run in
                run.ask {
                    let request = try decodeOptions(RecipeSummaryRequest.self, options, for: "resumir")
                    return try recipeJSON(try await bridge.summarize(request))
                }
            } ?? 0
        }
        puente.setObject(summarize, forKeyedSubscript: "resumir" as NSString)
        puente.setObject(
            asking {
                try await bridge.save()
                return "null"
            }, forKeyedSubscript: "guardar" as NSString)
        let publish: @convention(block) (String) -> Int = { [weak self] key in
            self?.assumeIsolated { run in
                run.ask {
                    try await bridge.publish(key)
                    return "null"
                }
            } ?? 0
        }
        puente.setObject(publish, forKeyedSubscript: "publicar" as NSString)
        let log: @convention(block) (String) -> Void = { bridge.log($0) }
        puente.setObject(log, forKeyedSubscript: "log" as NSString)
        return puente
    }

    private nonisolated func asking(
        _ work: @escaping @Sendable () async throws -> String
    ) -> @convention(block) () -> Int {
        { [weak self] in self?.assumeIsolated { $0.ask(work) } ?? 0 }
    }

    private func ask(_ work: @escaping @Sendable () async throws -> String) -> Int {
        nextId += 1
        let id = nextId
        pending.insert(id)
        Task { [weak self] in
            let result: Result<String, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            await self?.settle(id, result)
        }
        return id
    }

    private func settle(_ id: Int, _ result: Result<String, any Error>) {
        guard !finished, pending.remove(id) != nil, let prelude else { return }
        let entered = ContinuousClock.now
        switch result {
        case .success(let json):
            prelude.objectForKeyedSubscript("resolver").call(withArguments: [id, json])
        case .failure(let error):
            let failure = jsError(for: error) as Any
            prelude.objectForKeyedSubscript("rechazar").call(withArguments: [id, failure])
        }
        afterEntry(since: entered)
    }

    private func afterEntry(since entered: ContinuousClock.Instant) {
        guard !finished else { return }
        let elapsed = ContinuousClock.now - entered
        if let failure = takeException() {
            finish(.failure(
                failure.contains("terminated") ? RecipeError.timedOut(timeLimit) : RecipeError.failed(failure)))
        } else if pending.isEmpty {
            finish(.failure(
                elapsed >= .seconds(timeLimit) ? RecipeError.timedOut(timeLimit) : RecipeError.stalled))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard !finished else { return }
        finished = true
        pending.removeAll()
        continuation?.resume(with: result)
        continuation = nil
    }

    private func takeException() -> String? {
        defer { exception = nil }
        return exception
    }

    private func jsError(for error: any Error) -> JSValue? {
        nextId += 1
        swiftErrors[nextId] = error
        let code = (error as? TranscriptionError)?.isBackendUnavailable == true ? "no-disponible" : "fallo"
        return prelude?.objectForKeyedSubscript("error").call(withArguments: ["\(error)", code, nextId])
    }

    private func swiftError(token: Int?, message: String) -> any Error {
        if let token, let original = swiftErrors[token] { return original }
        return RecipeError.failed(message)
    }
}

private func decodeOptions<Options: Decodable>(
    _ type: Options.Type, _ json: String, for capability: String
) throws -> Options {
    do {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
        throw RecipeError.failed("las opciones de \(capability) no son válidas: \(error)")
    }
}

private func errorToken(_ value: JSValue?) -> Int? {
    guard let value, value.isObject, let token = value.objectForKeyedSubscript("__token"), token.isNumber
    else { return nil }
    return Int(token.toInt32())
}

func describe(_ value: JSValue?) -> String {
    guard let value else { return "error desconocido" }
    let message = value.toString() ?? "error desconocido"
    guard value.isObject, let line = value.objectForKeyedSubscript("line"), line.isNumber else { return message }
    return "\(message) (línea \(line.toInt32()))"
}
