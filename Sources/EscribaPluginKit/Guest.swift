import Foundation

#if arch(wasm32)
@_extern(wasm, module: "escriba", name: "call")
@_extern(c)
private func escriba_call(_ pointer: UnsafePointer<UInt8>, _ count: Int32) -> Int32

@_extern(wasm, module: "escriba", name: "take")
@_extern(c)
private func escriba_take(_ pointer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32

@_extern(wasm, module: "escriba", name: "respond")
@_extern(c)
private func escriba_respond(_ pointer: UnsafePointer<UInt8>, _ count: Int32)

@_silgen_name("swift_task_donateThreadToGlobalExecutorUntil")
private func donateThreadToGlobalExecutorUntil(
    _ condition: @convention(c) (UnsafeMutableRawPointer?) -> Bool, _ context: UnsafeMutableRawPointer?)

private func take(_ count: Int32) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: Int(count))
    let got = buffer.withUnsafeMutableBufferPointer { escriba_take($0.baseAddress!, Int32($0.count)) }
    guard got == count else { throw HostError("el host entregó \(got) bytes de \(count)") }
    return Data(buffer)
}

public func hostCall(_ request: HostRequest) throws -> HostResponse {
    let payload = [UInt8](try pluginJSONEncoder().encode(request))
    let needed = payload.withUnsafeBufferPointer { escriba_call($0.baseAddress!, Int32($0.count)) }
    guard needed >= 0 else { throw HostError("el host rechazó la llamada") }
    let response = try pluginJSONDecoder().decode(HostResponse.self, from: try take(needed))
    if let error = response.error { throw HostError(error) }
    return response
}

public func answer(_ response: PluginResponse) {
    let data = [UInt8]((try? pluginJSONEncoder().encode(response)) ?? Data())
    data.withUnsafeBufferPointer { escriba_respond($0.baseAddress!, Int32($0.count)) }
}

public func hostLog(_ message: String) {
    _ = try? hostCall(HostRequest(op: .log, message: message))
}

nonisolated(unsafe) private var finished = false

public func handle(_ count: Int32, _ serve: @escaping @Sendable (PluginRequest) async throws -> PluginResponse) -> Int32 {
    let request: PluginRequest
    do {
        request = try pluginJSONDecoder().decode(PluginRequest.self, from: try take(count))
    } catch {
        answer(.failure(error))
        return 1
    }
    finished = false
    Task {
        do {
            answer(try await serve(request))
        } catch {
            answer(.failure(error))
        }
        finished = true
    }
    donateThreadToGlobalExecutorUntil({ _ in finished }, nil)
    return 0
}
#else
public func hostCall(_ request: HostRequest) throws -> HostResponse {
    throw HostError("este binario no es un plugin: compílalo con el SDK de WebAssembly")
}

public func answer(_ response: PluginResponse) {
    print(String(decoding: (try? pluginJSONEncoder().encode(response)) ?? Data(), as: UTF8.self))
}

public func hostLog(_ message: String) {}

public func handle(_ count: Int32, _ serve: @escaping @Sendable (PluginRequest) async throws -> PluginResponse) -> Int32 {
    1
}
#endif
