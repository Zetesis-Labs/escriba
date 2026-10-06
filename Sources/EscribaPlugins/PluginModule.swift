import Foundation
import Synchronization
import EscribaCore
import EscribaEngine
import EscribaPluginKit
import WasmKit
import WasmKitWASI

public struct PluginPermissions: Sendable {
    public var hosts: [String]
    public var folder: URL?
    public var secrets: [String: String]

    public init(hosts: [String] = [], folder: URL? = nil, secrets: [String: String] = [:]) {
        self.hosts = hosts
        self.folder = folder
        self.secrets = secrets
    }

    public static let none = PluginPermissions()
}

public typealias HostHTTP = @Sendable (HostRequest) throws -> HostResponse

public struct PluginOutcome: Sendable, Equatable {
    public let response: PluginResponse
    public let elapsed: Duration
}

public final class PluginModule: Sendable {
    public let url: URL
    private let module: Module
    private let http: HostHTTP
    private let session = Mutex<Session?>(nil)

    public init(contentsOf url: URL, http: @escaping HostHTTP = urlSessionHostHTTP) throws {
        self.url = url
        self.http = http
        module = try parseWasm(bytes: [UInt8](try Data(contentsOf: url)))
    }

    public func describe() throws -> PluginManifest {
        let outcome = try run(PluginRequest(command: .describe), permissions: .none)
        if let error = outcome.response.error { throw HostError(error) }
        guard let manifest = outcome.response.manifest else { throw HostError("el plugin no se describe") }
        guard manifest.contract == pluginContractVersion else {
            throw HostError("el plugin habla el contrato \(manifest.contract) y esta app el \(pluginContractVersion)")
        }
        return manifest
    }

    public func run(_ request: PluginRequest, permissions: PluginPermissions) throws -> PluginOutcome {
        try session.withLock { slot in
            let started = ContinuousClock.now
            let session: Session
            if let live = slot {
                session = live
            } else {
                session = try Session(module: module, http: http)
                slot = session
            }
            do {
                let response = try session.call(request, permissions: permissions)
                return PluginOutcome(response: response, elapsed: ContinuousClock.now - started)
            } catch {
                slot = nil
                throw error
            }
        }
    }

    public func run(_ request: PluginRequest, permissions: PluginPermissions) async throws -> PluginOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try self.run(request, permissions: permissions) }) }
            thread.stackSize = 16 << 20
            thread.start()
        }
    }
}

final class Session: @unchecked Sendable {
    private let host: HostCalls
    private let bridge: WASIBridgeToHost
    private let engine: Engine
    private let store: Store
    private let instance: Instance
    private let handle: Function
    private let stdout: Pipe
    private let stderr: Pipe

    init(module: Module, http: @escaping HostHTTP) throws {
        stdout = Pipe()
        stderr = Pipe()
        forward(stdout, prefix: "plugin")
        forward(stderr, prefix: "plugin!")
        bridge = try WASIBridgeToHost(
            environment: ["TZ": TimeZone.current.identifier],
            preopens: [WASIBridgeToHost.Preopen(guestPath: "/usr/share/zoneinfo", hostPath: "/usr/share/zoneinfo")],
            stdin: FileHandle.nullDevice.fileDescriptor,
            stdout: stdout.fileHandleForWriting.fileDescriptor,
            stderr: stderr.fileHandleForWriting.fileDescriptor)
        host = HostCalls(http: http)
        engine = Engine()
        store = Store(engine: engine)
        var imports = Imports()
        bridge.link(to: &imports, store: store)
        let host = host
        imports.define(module: "escriba", name: "call", Function(store: store, parameters: [.i32, .i32], results: [.i32]) { caller, args in
            guard let memory = caller.instance?.exports[memory: "memory"] else { return [.i32(UInt32(bitPattern: -1))] }
            let bytes = memory.withUnsafeMutableBufferPointer(offset: UInt(args[0].i32), count: Int(args[1].i32)) { Data($0) }
            return [.i32(UInt32(host.call(bytes)))]
        })
        imports.define(module: "escriba", name: "take", Function(store: store, parameters: [.i32, .i32], results: [.i32]) { caller, args in
            guard let memory = caller.instance?.exports[memory: "memory"] else { return [.i32(0)] }
            let pending = host.take()
            let count = min(pending.count, Int(args[1].i32))
            memory.withUnsafeMutableBufferPointer(offset: UInt(args[0].i32), count: count) { buffer in
                pending.withUnsafeBytes { source in
                    if count > 0 { buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count) }
                }
            }
            return [.i32(UInt32(count))]
        })
        imports.define(module: "escriba", name: "respond", Function(store: store, parameters: [.i32, .i32]) { caller, args in
            guard let memory = caller.instance?.exports[memory: "memory"] else { return [] }
            let bytes = memory.withUnsafeMutableBufferPointer(offset: UInt(args[0].i32), count: Int(args[1].i32)) { Data($0) }
            host.respond(bytes)
            return []
        })
        do {
            instance = try module.instantiate(store: store, imports: imports)
            guard let initialize = instance.exports[function: "_initialize"],
                let handle = instance.exports[function: "escriba_handle"]
            else { throw HostError("el módulo no es un plugin de Escriba: le faltan _initialize o escriba_handle") }
            self.handle = handle
            _ = try initialize()
        } catch {
            try? bridge.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            throw error
        }
    }

    func call(_ request: PluginRequest, permissions: PluginPermissions) throws -> PluginResponse {
        let input = try pluginJSONEncoder().encode(request)
        host.prepare(input, permissions: permissions)
        do {
            _ = try handle([.i32(UInt32(input.count))])
        } catch {
            throw HostError("el plugin se rompió: \(error)")
        }
        guard let output = host.takeResponse() else { throw HostError("el plugin no respondió") }
        do {
            return try pluginJSONDecoder().decode(PluginResponse.self, from: output)
        } catch {
            throw HostError("respuesta ilegible del plugin: \(String(decoding: output.prefix(300), as: UTF8.self))")
        }
    }

    deinit {
        try? bridge.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }
}

private func forward(_ pipe: Pipe, prefix: String) {
    let handle = pipe.fileHandleForReading
    let thread = Thread {
        var rest = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            rest.append(chunk)
            while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: rest[rest.startIndex..<newline], as: UTF8.self)
                rest.removeSubrange(rest.startIndex...newline)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { Log.info("\(prefix): \(line)") }
            }
        }
    }
    thread.start()
}

private final class HostCalls: Sendable {
    private struct State {
        var permissions = PluginPermissions.none
        var pending = Data()
        var response: Data?
    }

    private let http: HostHTTP
    private let state = Mutex(State())

    init(http: @escaping HostHTTP) {
        self.http = http
    }

    func prepare(_ input: Data, permissions: PluginPermissions) {
        state.withLock { $0 = State(permissions: permissions, pending: input, response: nil) }
    }

    func takeResponse() -> Data? {
        state.withLock { $0.response }
    }

    func respond(_ bytes: Data) {
        state.withLock { $0.response = bytes }
    }

    func call(_ bytes: Data) -> Int {
        let permissions = state.withLock { $0.permissions }
        let response: HostResponse
        do {
            response = try serve(try pluginJSONDecoder().decode(HostRequest.self, from: bytes), permissions: permissions)
        } catch {
            response = HostResponse(error: "\(error)")
        }
        let encoded = (try? pluginJSONEncoder().encode(response)) ?? Data()
        state.withLock { $0.pending = encoded }
        return encoded.count
    }

    func take() -> Data {
        state.withLock { state in
            defer { state.pending = Data() }
            return state.pending
        }
    }

    private func serve(_ request: HostRequest, permissions: PluginPermissions) throws -> HostResponse {
        switch request.op {
        case .log:
            Log.info("plugin: \(request.message ?? "")")
            return HostResponse()
        case .http:
            return try http(try allowed(request, permissions: permissions))
        case .read, .list, .write, .remove:
            return try file(request, permissions: permissions)
        }
    }

    private func allowed(_ request: HostRequest, permissions: PluginPermissions) throws -> HostRequest {
        guard let raw = request.url, let url = URL(string: raw), let host = url.host()?.lowercased() else {
            throw HostError("URL inválida: \(request.url ?? "")")
        }
        guard url.scheme?.lowercased() == "https" else { throw HostError("solo se permite https: \(raw)") }
        guard permissions.hosts.contains(where: { host == $0.lowercased() || host.hasSuffix("." + $0.lowercased()) }) else {
            throw HostError("el plugin no tiene permiso para hablar con \(host)")
        }
        var copy = request
        copy.headers = (request.headers ?? [:]).mapValues { substitutingSecrets($0, secrets: permissions.secrets) }
        return copy
    }

    private func file(_ request: HostRequest, permissions: PluginPermissions) throws -> HostResponse {
        guard let root = permissions.folder else { throw HostError("el plugin no tiene una carpeta asignada") }
        let files = FileManager.default
        func target(_ path: String?) throws -> URL {
            guard let path, !path.isEmpty else { throw HostError("falta la ruta") }
            let url = root.appending(path: path).standardizedFileURL
            guard url.path(percentEncoded: false).hasPrefix(root.standardizedFileURL.path(percentEncoded: false)) else {
                throw HostError("la ruta \(path) se sale de la carpeta")
            }
            return url
        }
        switch request.op {
        case .read:
            let url = try target(request.path)
            guard files.fileExists(atPath: url.path(percentEncoded: false)) else { return HostResponse() }
            return HostResponse(contents: try String(contentsOf: url, encoding: .utf8))
        case .list:
            return HostResponse(paths: try markdownPaths(under: root))
        case .write:
            let url = try target(request.path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (request.contents ?? "").write(to: url, atomically: true, encoding: .utf8)
            return HostResponse()
        case .remove:
            let url = try target(request.path)
            if files.fileExists(atPath: url.path(percentEncoded: false)) { try files.removeItem(at: url) }
            return HostResponse()
        default:
            throw HostError("operación no admitida")
        }
    }
}

private func markdownPaths(under root: URL) throws -> [String] {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var paths: [String] = []
    let prefix = root.standardizedFileURL.path(percentEncoded: false)
    while case let url as URL = walker.nextObject() {
        guard url.pathExtension == "md" else { continue }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        paths.append(String(path.dropFirst(prefix.count)).drop { $0 == "/" }.description)
    }
    return paths.sorted()
}

public let urlSessionHostHTTP: HostHTTP = { request in
    guard let url = URL(string: request.url ?? "") else { throw HostError("URL inválida") }
    var native = URLRequest(url: url, timeoutInterval: 120)
    native.httpMethod = request.method ?? "GET"
    native.httpBody = request.body
    for (name, value) in request.headers ?? [:] { native.setValue(value, forHTTPHeaderField: name) }
    let box = Mutex<Result<HostResponse, Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: native) { data, response, error in
        let result: Result<HostResponse, Error>
        if let error {
            result = .failure(error)
        } else {
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            result = .success(HostResponse(status: http?.statusCode ?? 0, headers: headers, body: data ?? Data()))
        }
        box.withLock { $0 = result }
        done.signal()
    }.resume()
    done.wait()
    return try box.withLock { $0 }!.get()
}
