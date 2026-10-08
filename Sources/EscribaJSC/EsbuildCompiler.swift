import CryptoKit
import Foundation
import JavaScriptCore
import EscribaCore
import EscribaEngine

public final class EsbuildCompiler: Sendable {
    private let host: EsbuildHost

    public init(tools: URL, zod: URL? = nil, idleAfter: TimeInterval = 300, inspectionLimit: Double = 2) {
        host = EsbuildHost(tools: tools, zod: zod, idleAfter: idleAfter, inspectionLimit: inspectionLimit)
    }

    public var isLoaded: Bool {
        get async { await host.isLoaded }
    }

    public var toolchain: RecipeToolchain {
        let host = host
        return RecipeToolchain(
            compile: { files, entry in try await host.compile(files: files, entry: entry) },
            inspect: { source in await host.inspect(source) },
            fingerprint: recipeFingerprint)
    }
}

public func recipeFingerprint(_ source: String) -> String {
    String(SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
}

public enum EsbuildError: Error, Equatable, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let message): "esbuild falló: \(message)"
        }
    }
}

private struct CompileRequest: Encodable {
    let archivos: [String: String]
    let entrada: String
}

private struct CompileReply: Decodable {
    let codigo: String?
    let mapa: String?
    let errores: [RecipeBuildIssue]?
}

private struct InspectionReply: Decodable {
    let nombre: String?
    let problema: String?
}

actor EsbuildHost {
    private let executor: RunLoopExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private let tools: URL
    private let zod: URL?
    private let idleAfter: TimeInterval
    private let inspectionLimit: Double
    private var context: JSContext?
    private var driver: JSValue?
    private var loading: Task<Void, any Error>?
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    private var timers: [Int: Timer] = [:]
    private var idleTimer: Timer?
    private var exception: String?
    private var nextId = 0

    init(tools: URL, zod: URL?, idleAfter: TimeInterval, inspectionLimit: Double) {
        executor = RunLoopExecutor(name: "dev.ruben.escriba.compilador")
        self.tools = tools
        self.zod = zod
        self.idleAfter = idleAfter
        self.inspectionLimit = inspectionLimit
    }

    var isLoaded: Bool { context != nil }

    func compile(files: [String: String], entry: String) async throws -> RecipeCompilation {
        idleTimer?.invalidate()
        defer { scheduleUnload() }
        try await ready()
        let request = String(decoding: try JSONEncoder().encode(CompileRequest(archivos: files, entrada: entry)), as: UTF8.self)
        let reply = try await settle(driver?.invokeMethod("compilar", withArguments: [request]))
        let decoded = try JSONDecoder().decode(CompileReply.self, from: Data(reply.utf8))
        if let code = decoded.codigo { return .compiled(code, sourceMap: decoded.mapa) }
        return .failed(decoded.errores ?? [RecipeBuildIssue(file: entry, text: "esbuild no dio ni código ni errores")])
    }

    func inspect(_ source: String) -> RecipeInspection {
        guard (try? timeLimitWorks.get()) != nil, let setLimit = executionTimeLimit(), let context = JSContext() else {
            return .invalid("no se puede comprobar la receta: JavaScriptCore no tiene tiempo límite")
        }
        nonisolated(unsafe) var failure: String?
        context.exceptionHandler = { _, value in failure = describe(value) }
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), inspectionLimit, { _, _ in true }, nil)
        context.evaluateScript(source, withSourceURL: URL(string: "receta://paquete.js"))
        if let failure {
            return .invalid(
                failure.contains("terminated")
                    ? "la receta tarda más de \(inspectionLimit.formatted()) s en cargar: revisa el código que está fuera de las funciones"
                    : failure)
        }
        let reply = context.evaluateScript(inspectionSource)?.toString() ?? ""
        guard let decoded = try? JSONDecoder().decode(InspectionReply.self, from: Data(reply.utf8)) else {
            return .invalid(failure ?? "no se pudo comprobar la receta")
        }
        if let name = decoded.nombre { return .valid(name: name) }
        return .invalid(decoded.problema ?? "no se pudo comprobar la receta")
    }

    private func ready() async throws {
        if let loading {
            try await loading.value
            return
        }
        let task = Task { try await self.load() }
        loading = task
        do {
            try await task.value
        } catch {
            unload()
            throw error
        }
    }

    private func load() async throws {
        _ = timeLimitWorks
        let browser = try String(contentsOf: tools.appending(path: "browser.js"), encoding: .utf8)
        let bytes = try Data(contentsOf: tools.appending(path: "esbuild.wasm"))
        guard let context = JSContext() else { throw EsbuildError.failed("JavaScriptCore no arranca") }
        context.exceptionHandler = { [weak self] _, value in
            let message = describe(value)
            self?.assumeIsolated { $0.exception = message }
        }
        let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, milliseconds in
            self?.assumeIsolated { $0.schedule(id, after: milliseconds) }
        }
        context.setObject(schedule, forKeyedSubscript: "__programar" as NSString)
        let zod = zod
        let readZod: @convention(block) (String) -> String? = { path in
            zod.flatMap { ZodPackage.file(path, in: $0) }
        }
        context.setObject(readZod, forKeyedSubscript: "__zod" as NSString)
        context.evaluateScript(esbuildPolyfills, withSourceURL: URL(string: "escriba://polyfills.js"))
        context.evaluateScript(browser, withSourceURL: URL(string: "esbuild://browser.js"))
        let driver = context.evaluateScript(esbuildDriver, withSourceURL: URL(string: "escriba://compilador.js"))
        if let exception {
            self.exception = nil
            throw EsbuildError.failed(exception)
        }

        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
        bytes.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        let buffer = JSObjectMakeArrayBufferWithBytesNoCopy(
            context.jsGlobalContextRef, memory, bytes.count, { pointer, _ in pointer?.deallocate() }, nil, nil)
        context.setObject(JSValue(jsValueRef: buffer, in: context), forKeyedSubscript: "__wasm" as NSString)
        self.context = context
        self.driver = driver

        _ = try await settle(context.evaluateScript(
            "WebAssembly.compile(__wasm).then((modulo) => { globalThis.__modulo = modulo; delete globalThis.__wasm })"))
        _ = try await settle(driver?.invokeMethod("arrancar", withArguments: []))
        Log.info("recetas: esbuild \(EsbuildTools.version) cargado")
    }

    private func settle(_ promise: JSValue?) async throws -> String {
        guard let context, let promise, promise.isObject else { throw EsbuildError.failed("esbuild no está cargado") }
        nextId += 1
        let id = nextId
        let done: @convention(block) (JSValue?) -> Void = { [weak self] value in
            let text = value.map { $0.isUndefined ? "" : $0.toString() ?? "" } ?? ""
            self?.assumeIsolated { $0.resume(id, .success(text)) }
        }
        let failed: @convention(block) (JSValue?) -> Void = { [weak self] value in
            let text = describe(value)
            self?.assumeIsolated { $0.resume(id, .failure(EsbuildError.failed(text))) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            promise.invokeMethod("then", withArguments: [
                JSValue(object: done, in: context) as Any, JSValue(object: failed, in: context) as Any,
            ])
        }
    }

    private func resume(_ id: Int, _ result: Result<String, any Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func schedule(_ id: Int, after milliseconds: Double) {
        let timer = Timer(timeInterval: milliseconds / 1000, repeats: false) { [weak self] _ in
            self?.assumeIsolated { $0.fire(id) }
        }
        RunLoop.current.add(timer, forMode: .default)
        timers[id] = timer
    }

    private func fire(_ id: Int) {
        timers[id] = nil
        context?.objectForKeyedSubscript("__disparar").call(withArguments: [id])
    }

    private func scheduleUnload() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: idleAfter, repeats: false) { [weak self] _ in
            self?.assumeIsolated { $0.unloadIfIdle() }
        }
        RunLoop.current.add(timer, forMode: .default)
        idleTimer = timer
    }

    private func unloadIfIdle() {
        guard pending.isEmpty, context != nil else { return }
        unload()
        Log.info("recetas: esbuild descargado tras \(Int(idleAfter)) s sin compilar")
    }

    private func unload() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
        driver = nil
        context = nil
        loading = nil
    }
}
