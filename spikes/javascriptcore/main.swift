import Foundation
import JavaScriptCore

let wasmPath = CommandLine.arguments[1]
let folder = CommandLine.arguments[2]
let clock = ContinuousClock()

func serve(_ raw: String) -> String {
    let req = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
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
    return String(decoding: try! JSONSerialization.data(withJSONObject: res), as: UTF8.self)
}

let ctx = JSContext()!
ctx.exceptionHandler = { _, e in print("JS error:", e?.toString() ?? "") }
let hostCall: @convention(block) (String) -> String = { serve($0) }
let hostRead: @convention(block) (String) -> String = { path in
    (try? Data(contentsOf: URL(fileURLWithPath: path)))?.base64EncodedString() ?? ""
}
let hostLog: @convention(block) (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
let hostNow: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1e9 }
ctx.setObject(hostCall, forKeyedSubscript: "hostCall" as NSString)
ctx.setObject(hostRead, forKeyedSubscript: "hostRead" as NSString)
ctx.setObject(hostLog, forKeyedSubscript: "hostLog" as NSString)
ctx.setObject(hostNow, forKeyedSubscript: "hostNow" as NSString)

let wasmData = try Data(contentsOf: URL(fileURLWithPath: wasmPath))
let bytesRef = wasmData.withUnsafeBytes { raw -> JSObjectRef in
    let copy = UnsafeMutableRawPointer.allocate(byteCount: raw.count, alignment: 16)
    copy.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
    return JSObjectMakeTypedArrayWithBytesNoCopy(ctx.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, copy, raw.count, nil, nil, nil)!
}
ctx.setObject(JSValue(jsValueRef: bytesRef, in: ctx), forKeyedSubscript: "wasmBytes" as NSString)

let shim = """
const enc = { encode(str) { const out = []; for (const ch of str) { let c = ch.codePointAt(0); if (c < 0x80) out.push(c); else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63)); else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); } return Uint8Array.from(out); } };
const dec = { decode(a) { let s = "", i = 0; while (i < a.length) { const b = a[i++]; let c; if (b < 0x80) c = b; else if (b < 0xe0) c = ((b & 31) << 6) | (a[i++] & 63); else if (b < 0xf0) c = ((b & 15) << 12) | ((a[i++] & 63) << 6) | (a[i++] & 63); else c = ((b & 7) << 18) | ((a[i++] & 63) << 12) | ((a[i++] & 63) << 6) | (a[i++] & 63); s += String.fromCodePoint(c); } return s; } };
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function atob(str) { str = str.replace(/=+$/, ""); let out = "", bits = 0, acc = 0; for (const ch of str) { acc = (acc << 6) | B64.indexOf(ch); bits += 6; if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); } } return out; }
const performance = { now: () => hostNow() / 1e6 };
let memory, pending = new Uint8Array(0), response = null;
const files = {}; let nextFd = 4;
const PREOPEN = "/usr/share/zoneinfo";
const mem = () => new DataView(memory.buffer);
const u8 = () => new Uint8Array(memory.buffer);
const b64 = (s) => { const bin = atob(s); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };
const wasi = {
  args_sizes_get(argc, argv_buf_size) { mem().setUint32(argc, 0, true); mem().setUint32(argv_buf_size, 0, true); return 0; },
  args_get() { return 0; },
  environ_sizes_get(c, s) { mem().setUint32(c, 1, true); mem().setUint32(s, 7, true); return 0; },
  environ_get(envp, buf) { u8().set(enc.encode("TZ=UTC\\0"), buf); mem().setUint32(envp, buf, true); return 0; },
  clock_res_get(id, out) { mem().setBigUint64(out, 1000n, true); return 0; },
  clock_time_get(id, prec, out) { mem().setBigUint64(out, BigInt(Math.round(hostNow())), true); return 0; },
  random_get(ptr, len) { const a = u8(); for (let i = 0; i < len; i++) a[ptr + i] = (Math.random() * 256) | 0; return 0; },
  proc_exit(code) { throw new Error("proc_exit " + code); },
  poll_oneoff(subs, events, n, nout) { mem().setUint32(nout, 0, true); return 0; },
  fd_prestat_get(fd, out) { if (fd !== 3) return 8; mem().setUint8(out, 0); mem().setUint32(out + 4, PREOPEN.length, true); return 0; },
  fd_prestat_dir_name(fd, path, len) { if (fd !== 3) return 8; u8().set(enc.encode(PREOPEN), path); return 0; },
  fd_fdstat_get(fd, out) { const type = fd === 3 ? 3 : (files[fd] ? 4 : 2); mem().setUint8(out, type); mem().setUint16(out + 2, 0, true); mem().setBigUint64(out + 8, 0xffffffffn, true); mem().setBigUint64(out + 16, 0xffffffffn, true); return 0; },
  fd_write(fd, iovs, n, nwritten) { let total = 0, text = ""; for (let i = 0; i < n; i++) { const p = mem().getUint32(iovs + i * 8, true), l = mem().getUint32(iovs + i * 8 + 4, true); text += dec.decode(u8().subarray(p, p + l)); total += l; } hostLog("[fd" + fd + "] " + text.trimEnd()); mem().setUint32(nwritten, total, true); return 0; },
  path_open(dirfd, dirflags, path, pathLen, oflags, rightsBase, rightsInh, fdflags, out) {
    if (dirfd !== 3) return 8;
    const name = dec.decode(u8().subarray(path, path + pathLen));
    const data = hostRead(PREOPEN + "/" + name);
    if (!data) return 44;
    const fd = nextFd++; files[fd] = { data: b64(data), pos: 0 }; mem().setUint32(out, fd, true); return 0;
  },
  fd_read(fd, iovs, n, nread) { const f = files[fd]; if (!f) return 8; let total = 0; for (let i = 0; i < n; i++) { const p = mem().getUint32(iovs + i * 8, true), l = mem().getUint32(iovs + i * 8 + 4, true); const chunk = f.data.subarray(f.pos, f.pos + l); u8().set(chunk, p); f.pos += chunk.length; total += chunk.length; if (chunk.length < l) break; } mem().setUint32(nread, total, true); return 0; },
  fd_seek(fd, offset, whence, out) { const f = files[fd]; if (!f) return 8; const o = Number(offset); f.pos = whence === 0 ? o : whence === 1 ? f.pos + o : f.data.length + o; mem().setBigUint64(out, BigInt(f.pos), true); return 0; },
  fd_close(fd) { delete files[fd]; return 0; },
};
const escriba = {
  call(ptr, len) { const res = hostCall(dec.decode(u8().subarray(ptr, ptr + len))); pending = enc.encode(res); return pending.length; },
  take(ptr, cap) { const n = Math.min(cap, pending.length); u8().set(pending.subarray(0, n), ptr); pending = new Uint8Array(0); return n; },
  respond(ptr, len) { response = dec.decode(u8().subarray(ptr, ptr + len)); },
};
let t = performance.now();
const module = new WebAssembly.Module(wasmBytes);
const tCompile = performance.now() - t; t = performance.now();
for (const imp of WebAssembly.Module.imports(module)) {
  if (imp.module === "wasi_snapshot_preview1" && !(imp.name in wasi)) {
    wasi[imp.name] = (...a) => { hostLog("wasi sin implementar: " + imp.name); return 52; };
  }
}
const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi, escriba });
memory = instance.exports.memory;
instance.exports._initialize();
const tInit = performance.now() - t;
function run(label, json) {
  pending = enc.encode(json); response = null;
  const t0 = performance.now();
  instance.exports.escriba_handle(pending.length);
  return label + ": " + (performance.now() - t0).toFixed(2) + " ms → " + (response || "").slice(0, 80);
}
"""
_ = ctx.evaluateScript(shim)
let cfg = "\"config\":{\"folder\":\"\(folder)\"},\"state\":{},\"timeZone\":\"UTC\""
let runs: [(String, String)] = [
    ("describe", "{\"command\":\"describe\",\(cfg)}"), ("form", "{\"command\":\"form\",\(cfg)}"), ("form 2", "{\"command\":\"form\",\(cfg)}"),
    ("preview", "{\"command\":\"preview\",\(cfg)}"),
    ("publish", "{\"command\":\"publish\",\(cfg),\"note\":{\"key\":\"ejemplo\",\"url\":\"/n/a.m4a\",\"startedAt\":\"2026-10-05T17:00:00Z\",\"segments\":[{\"start\":0,\"end\":2,\"speaker\":\"Ana\",\"text\":\"Hola.\",\"words\":[]}],\"text\":\"Hola.\",\"digest\":{\"title\":\"T\",\"summary\":\"R\",\"tags\":[\"x\"]}}}"),
    ("preview 2", "{\"command\":\"preview\",\(cfg)}"),
]
print("compilar: \(ctx.evaluateScript("tCompile.toFixed(0)")!) ms; instanciar+_initialize: \(ctx.evaluateScript("tInit.toFixed(0)")!) ms")
for _ in 1...30 { _ = ctx.evaluateScript("run('form', '\(runs[1].1.replacingOccurrences(of: "\\", with: "\\\\"))')") }
print("tras 30 formularios:")
for (label, json) in runs {
    let escaped = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    print(ctx.evaluateScript("run('\(label)', '\(escaped)')")!.toString()!)
}
