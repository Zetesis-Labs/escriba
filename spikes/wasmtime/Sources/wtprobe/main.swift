import CWasmtime
import Foundation

nonisolated(unsafe) var pending = Data()
nonisolated(unsafe) var response: Data?
nonisolated(unsafe) var folder = ""

func serve(_ raw: Data) -> Data {
    let req = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    let op = req["op"] as? String ?? ""
    let target = { (p: String) in folder + "/" + p }
    var res: [String: Any] = [:]
    switch op {
    case "log": FileHandle.standardError.write(Data("[plugin] \(req["message"] ?? "")\n".utf8))
    case "read": if let p = req["path"] as? String, let s = try? String(contentsOfFile: target(p), encoding: .utf8) { res["contents"] = s }
    case "list":
        var paths: [String] = []
        if let e = FileManager.default.enumerator(atPath: folder) { while let f = e.nextObject() as? String { if f.hasSuffix(".md") { paths.append(f) } } }
        res["paths"] = paths.sorted()
    case "write":
        if let p = req["path"] as? String {
            try? FileManager.default.createDirectory(atPath: (target(p) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? (req["contents"] as? String ?? "").write(toFile: target(p), atomically: true, encoding: .utf8)
        }
    case "remove": if let p = req["path"] as? String { try? FileManager.default.removeItem(atPath: target(p)) }
    default: res["error"] = "op \(op) no disponible"
    }
    return try! JSONSerialization.data(withJSONObject: res)
}

func memory(_ caller: OpaquePointer?) -> UnsafeMutablePointer<UInt8> {
    var item = wasmtime_extern_t()
    _ = wasmtime_caller_export_get(caller, "memory", 6, &item)
    let ctx = wasmtime_caller_context(caller)
    return wasmtime_memory_data(ctx, &item.of.memory)
}

let callCB: wasmtime_func_callback_t = { _, caller, args, _, results, _ in
    let base = memory(caller)
    let ptr = Int(args![0].of.i32), len = Int(args![1].of.i32)
    pending = serve(Data(bytes: base + ptr, count: len))
    results![0].kind = UInt8(WASMTIME_I32); results![0].of.i32 = Int32(pending.count)
    return nil
}
let takeCB: wasmtime_func_callback_t = { _, caller, args, _, results, _ in
    let base = memory(caller)
    let ptr = Int(args![0].of.i32), cap = Int(args![1].of.i32)
    let n = min(cap, pending.count)
    pending.withUnsafeBytes { src in if n > 0 { (base + ptr).update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: n) } }
    pending = Data()
    results![0].kind = UInt8(WASMTIME_I32); results![0].of.i32 = Int32(n)
    return nil
}
let respondCB: wasmtime_func_callback_t = { _, caller, args, _, _, _ in
    let base = memory(caller)
    response = Data(bytes: base + Int(args![0].of.i32), count: Int(args![1].of.i32))
    return nil
}

@MainActor func check(_ error: OpaquePointer?, trap: OpaquePointer? = nil, _ what: String) {
    if error == nil && trap == nil { return }
    var name = wasm_name_t()
    if error != nil {
        wasmtime_error_message(error, &name)
    } else {
        wasm_trap_message(trap, &name)
    }
    let message = String(decoding: UnsafeRawBufferPointer(start: name.data, count: name.size), as: UTF8.self)
    fatalError("\(what): \(message)")
}

let wasmPath = CommandLine.arguments[1]
folder = CommandLine.arguments[2]
let clock = ContinuousClock()

let engine = wasm_engine_new()
let store = wasmtime_store_new(engine, nil, nil)
let ctx = wasmtime_store_context(store)
let wasi = wasi_config_new()
var names: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("TZ"))]
var values: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("UTC"))]
_ = names.withUnsafeMutableBufferPointer { n in values.withUnsafeMutableBufferPointer { v in wasi_config_set_env(wasi, 1, n.baseAddress, v.baseAddress) } }
if ProcessInfo.processInfo.environment["SIN_ZONEINFO"] == nil {
    _ = wasi_config_preopen_dir(wasi, "/usr/share/zoneinfo", "/usr/share/zoneinfo", false)
} else {
    print("sin preopen de zoneinfo")
}
wasi_config_inherit_stdout(wasi); wasi_config_inherit_stderr(wasi)
check(wasmtime_context_set_wasi(ctx, wasi), "wasi")

let linker = wasmtime_linker_new(engine)
check(wasmtime_linker_define_wasi(linker), "define wasi")
let t21 = wasm_functype_new_2_1(wasm_valtype_new_i32(), wasm_valtype_new_i32(), wasm_valtype_new_i32())
let t20 = wasm_functype_new_2_0(wasm_valtype_new_i32(), wasm_valtype_new_i32())
check(wasmtime_linker_define_func(linker, "escriba", 7, "call", 4, t21, callCB, nil, nil), "call")
check(wasmtime_linker_define_func(linker, "escriba", 7, "take", 4, t21, takeCB, nil, nil), "take")
check(wasmtime_linker_define_func(linker, "escriba", 7, "respond", 7, t20, respondCB, nil, nil), "respond")

let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: wasmPath)))
var module: OpaquePointer?
let compile = clock.measure { check(wasmtime_module_new(engine, bytes, bytes.count, &module), "compilar") }
print("compilar módulo: \(compile)")
var serialized = wasm_byte_vec_t()
let serialize = clock.measure { check(wasmtime_module_serialize(module, &serialized), "serializar") }
var reloaded: OpaquePointer?
let deserialize = clock.measure { check(wasmtime_module_deserialize(engine, serialized.data, serialized.size, &reloaded), "deserializar") }
print("precompilado: serializar \(serialize), \(serialized.size / 1_048_576) MB; cargar precompilado \(deserialize)")
module = reloaded

let cfg = "\"config\":{\"folder\":\"\(folder)\"},\"state\":{},\"timeZone\":\"UTC\""
if ProcessInfo.processInfo.environment["COMANDO"] == nil {
var instance = wasmtime_instance_t()
var trap: OpaquePointer?
let inst = clock.measure { check(wasmtime_linker_instantiate(linker, ctx, module, &instance, &trap), trap: trap, "instanciar") }
var item = wasmtime_extern_t()
_ = wasmtime_instance_export_get(ctx, &instance, "_initialize", 11, &item)
var initialize = item.of.func
let initTime = clock.measure { check(wasmtime_func_call(ctx, &initialize, nil, 0, nil, 0, &trap), trap: trap, "_initialize") }
print("instanciar: \(inst) + _initialize: \(initTime)")
_ = wasmtime_instance_export_get(ctx, &instance, "escriba_handle", 14, &item)
var handle = item.of.func

@MainActor func run(_ label: String, _ json: String) {
    pending = Data(json.utf8); response = nil
    var arg = wasmtime_val_t(); arg.kind = UInt8(WASMTIME_I32); arg.of.i32 = Int32(pending.count)
    var result = wasmtime_val_t()
    let t = clock.measure { check(wasmtime_func_call(ctx, &handle, &arg, 1, &result, 1, &trap), trap: trap, label) }
    let out = String(decoding: response ?? Data(), as: UTF8.self)
    print("\(label): \(t) → \(out.prefix(90))")
}

run("describe", "{\"command\":\"describe\",\(cfg)}")
run("form", "{\"command\":\"form\",\(cfg)}")
run("form 2", "{\"command\":\"form\",\(cfg)}")
run("preview", "{\"command\":\"preview\",\(cfg)}")
run("publish", "{\"command\":\"publish\",\(cfg),\"note\":{\"key\":\"ejemplo\",\"url\":\"/n/a.m4a\",\"startedAt\":\"2026-10-05T17:00:00Z\",\"segments\":[{\"start\":0,\"end\":2,\"speaker\":\"Ana\",\"text\":\"Hola.\",\"words\":[]}],\"text\":\"Hola.\",\"digest\":{\"title\":\"T\",\"summary\":\"R\",\"tags\":[\"x\"]}}}")
run("preview 2", "{\"command\":\"preview\",\(cfg)}")
}

// Modo comando: una instancia por llamada, peticion por stdin y respuesta por stdout.
if ProcessInfo.processInfo.environment["COMANDO"] != nil {
    print("== modo comando (una instancia por llamada)")
    @MainActor func runCommand(_ label: String, _ json: String) {
        let out = NSTemporaryDirectory() + "escriba-out-\(UUID().uuidString).txt"
        let t = clock.measure {
            let store = wasmtime_store_new(engine, nil, nil)
            let ctx = wasmtime_store_context(store)
            let wasi = wasi_config_new()
            var names: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("TZ"))]
            var values: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("UTC"))]
            _ = names.withUnsafeMutableBufferPointer { n in values.withUnsafeMutableBufferPointer { v in wasi_config_set_env(wasi, 1, n.baseAddress, v.baseAddress) } }
            _ = wasi_config_preopen_dir(wasi, "/usr/share/zoneinfo", "/usr/share/zoneinfo", false)
            var input = wasm_byte_vec_t()
            let bytes = Array(json.utf8)
            wasm_byte_vec_new(&input, bytes.count, bytes.map { CChar(bitPattern: $0) })
            wasi_config_set_stdin_bytes(wasi, &input)
            _ = wasi_config_set_stdout_file(wasi, out)
            wasi_config_inherit_stderr(wasi)
            check(wasmtime_context_set_wasi(ctx, wasi), "wasi")
            var instance = wasmtime_instance_t()
            var trap: OpaquePointer?
            check(wasmtime_linker_instantiate(linker, ctx, module, &instance, &trap), trap: trap, "instanciar")
            var item = wasmtime_extern_t()
            _ = wasmtime_instance_export_get(ctx, &instance, "_start", 6, &item)
            var start = item.of.func
            let error = wasmtime_func_call(ctx, &start, nil, 0, nil, 0, &trap)
            if error != nil || trap != nil {
                var code: Int32 = -1
                if trap != nil, wasmtime_trap_code(trap, nil) == false, wasmtime_error_exit_status(error, &code) { }
            }
            wasmtime_store_delete(store)
        }
        let response = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        print("\(label): \(t) → \(response.split(whereSeparator: \.isNewline).last.map { String($0.prefix(80)) } ?? "")")
    }
    runCommand("describe", "{\"command\":\"describe\",\(cfg)}")
    runCommand("form", "{\"command\":\"form\",\(cfg)}")
    runCommand("form 2", "{\"command\":\"form\",\(cfg)}")
    runCommand("preview", "{\"command\":\"preview\",\(cfg)}")
    runCommand("publish", "{\"command\":\"publish\",\(cfg),\"note\":{\"key\":\"ejemplo\",\"url\":\"/n/a.m4a\",\"startedAt\":\"2026-10-05T17:00:00Z\",\"segments\":[{\"start\":0,\"end\":2,\"speaker\":\"Ana\",\"text\":\"Hola.\",\"words\":[]}],\"text\":\"Hola.\",\"digest\":{\"title\":\"T\",\"summary\":\"R\",\"tags\":[\"x\"]}}}")
}
