// Throwaway proof: run the browser build of esbuild-wasm inside JavaScriptCore.
// Usage: swift compiler/compile.swift PROJECT_ROOT ENTRY_RELATIVE BUNDLE_OUTPUT
import Foundation
import JavaScriptCore

guard CommandLine.arguments.count == 4 else {
    fputs("usage: swift compiler/compile.swift PROJECT_ROOT ENTRY_RELATIVE BUNDLE_OUTPUT\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let entry = CommandLine.arguments[2]
let output = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
let fm = FileManager.default
let rootPrefix = root.path + "/"

func readProjectData(_ relative: String) -> Data? {
    guard !relative.hasPrefix("/"), !relative.contains("\0") else { return nil }
    let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    guard file.path.hasPrefix(rootPrefix),
          (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          let data = try? Data(contentsOf: file), data.count < 40_000_000 else { return nil }
    return data
}
func readProjectFile(_ relative: String) -> String? {
    readProjectData(relative).flatMap { String(data: $0, encoding: .utf8) }
}

guard readProjectFile(entry) != nil else {
    fputs("entry is missing, unreadable, or outside project root: \(entry)\n", stderr)
    exit(1)
}
let browserPath = "node_modules/esbuild-wasm/lib/browser.js"
guard let browser = readProjectFile(browserPath), let wasm = readProjectData("node_modules/esbuild-wasm/esbuild.wasm") else {
    fputs("install esbuild-wasm@0.28.2 under \(root.path)/node_modules\n", stderr)
    exit(1)
}
guard let context = JSContext() else { fatalError("JavaScriptCore unavailable") }
var exception: String?
context.exceptionHandler = { _, value in exception = value?.toString() ?? "unknown JavaScript error" }

let read: @convention(block) (String) -> String? = { path in readProjectFile(path) }
context.setObject(read, forKeyedSubscript: "__read" as NSString)
var timers: [Int: Timer] = [:]
let schedule: @convention(block) (Int, Double) -> Void = { id, ms in
    let timer = Timer(timeInterval: max(0, ms) / 1000, repeats: false) { _ in
        timers[id] = nil
        context.objectForKeyedSubscript("__fire").call(withArguments: [id])
    }
    timers[id] = timer
    RunLoop.current.add(timer, forMode: .default)
}
context.setObject(schedule, forKeyedSubscript: "__schedule" as NSString)

let polyfills = #"""
var self = globalThis;
globalThis.console = { log() {}, warn() {}, error() {} };
globalThis.performance = { now: () => Date.now() };
globalThis.crypto = { getRandomValues(a) { for (let i = 0; i < a.length; i++) a[i] = Math.random() * 256 | 0; return a; } };
globalThis.TextEncoder = class { encode(s = "") { const b = unescape(encodeURIComponent(s)); return Uint8Array.from(b, x => x.charCodeAt(0)); } };
globalThis.TextDecoder = class { decode(v) { if (!v) return ""; const a = v instanceof Uint8Array ? v : new Uint8Array(v.buffer ?? v, v.byteOffset ?? 0, v.byteLength); let s = ""; for (let i = 0; i < a.length; i += 8192) s += String.fromCharCode.apply(null, a.subarray(i, i + 8192)); return decodeURIComponent(escape(s)); } };
const __timers = new Map(); let __nextTimer = 1;
globalThis.setTimeout = (fn, ms, ...args) => { const id = __nextTimer++; __timers.set(id, () => fn(...args)); __schedule(id, ms || 0); return id; };
globalThis.clearTimeout = id => __timers.delete(id);
globalThis.__fire = id => { const fn = __timers.get(id); __timers.delete(id); if (fn) fn(); };
"""#
context.evaluateScript(polyfills)
context.evaluateScript(browser)
if let exception { fputs("esbuild bootstrap: \(exception)\n", stderr); exit(1) }

let memory = UnsafeMutableRawPointer.allocate(byteCount: wasm.count, alignment: 16)
wasm.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: wasm.count)
let buffer = JSObjectMakeArrayBufferWithBytesNoCopy(context.jsGlobalContextRef, memory, wasm.count, { pointer, _ in pointer?.deallocate() }, nil, nil)
context.setObject(JSValue(jsValueRef: buffer, in: context), forKeyedSubscript: "__wasm" as NSString)

let driver = #"""
(() => {
  const compatibilityShims = new Set();
  const normalize = path => {
    const parts = [];
    for (const p of path.split('/')) {
      if (!p || p === '.') continue;
      if (p === '..') { if (!parts.length) throw Error(`path escapes project: ${path}`); parts.pop(); }
      else parts.push(p);
    }
    return parts.join('/');
  };
  const dirname = path => path.slice(0, path.lastIndexOf('/') + 1);
  const file = path => __read(path) != null;
  const candidates = path => [path, `${path}.ts`, `${path}.tsx`, `${path}.mjs`, `${path}.cjs`, `${path}.js`, `${path}.json`, `${path}/index.ts`, `${path}/index.mjs`, `${path}/index.cjs`, `${path}/index.js`, `${path}/index.json`];
  const existing = path => candidates(path).find(file);
  const packageJSON = dir => { const text = __read(`${dir}/package.json`); return text == null ? null : JSON.parse(text); };
  const chooseExport = (value, conditions, star = '') => {
    if (typeof value === 'string') return value.replaceAll('*', star);
    if (Array.isArray(value)) return value.map(v => chooseExport(v, conditions, star)).find(v => v !== undefined);
    if (value && typeof value === 'object') {
      for (const [key, branch] of Object.entries(value)) {
        if (key === 'default' || conditions.includes(key)) {
          const found = chooseExport(branch, conditions, star);
          if (found !== undefined) return found;
        }
      }
    }
  };
  const exported = (map, subpath, conditions) => {
    if (typeof map === 'string' || Array.isArray(map) || (map && !Object.keys(map).some(k => k.startsWith('.'))))
      return subpath === '.' ? chooseExport(map, conditions) : undefined;
    if (Object.hasOwn(map, subpath)) return chooseExport(map[subpath], conditions);
    for (const [key, value] of Object.entries(map)) {
      const at = key.indexOf('*'); if (at < 0) continue;
      const prefix = key.slice(0, at), suffix = key.slice(at + 1);
      if (subpath.startsWith(prefix) && subpath.endsWith(suffix))
        return chooseExport(value, conditions, subpath.slice(prefix.length, subpath.length - suffix.length));
    }
  };
  const packageName = spec => spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
  const resolve = args => {
    const spec = args.path;
    // Notion's webhook helper has an optional Node 18 crypto fallback. Its
    // browser build never needs it; a throwing module keeps the IIFE self-contained
    // and surfaces unsupported webhook signing when the fallback is invoked.
    if (spec === 'crypto' && args.importer === 'node_modules/@notionhq/client/build/src/webhooks.js') {
      compatibilityShims.add('notion-webhooks-optional-node-crypto');
      return { path: 'notion-optional-crypto', namespace: 'empty' };
    }
    if (spec.startsWith('node:') || ['fs','path','http','https','stream','crypto','buffer','util','os','url','events','assert','process','net','tls','zlib'].includes(spec))
      throw Error(`Node builtin is unavailable in JavaScriptCore: ${spec} (imported by ${args.importer})`);
    if (args.kind === 'entry-point') return { path: existing(normalize(spec)) ?? normalize(spec), namespace: 'project' };
    if (spec.startsWith('.') || spec.startsWith('/')) {
      if (spec.startsWith('/')) throw Error(`absolute import is unsupported: ${spec}`);
      const found = existing(normalize(dirname(args.importer) + spec));
      if (!found) throw Error(`cannot resolve ${spec} from ${args.importer}`);
      return { path: found, namespace: 'project' };
    }
    if (spec.startsWith('#')) throw Error(`package imports (#) unsupported: ${spec}`);
    const name = packageName(spec);
    const subpath = spec === name ? '.' : `.${spec.slice(name.length)}`;
    let dir = dirname(args.importer).replace(/\/$/, '');
    let pkgDir;
    while (true) {
      const candidate = (dir ? `${dir}/` : '') + `node_modules/${name}`;
      if (packageJSON(candidate)) { pkgDir = candidate; break; }
      if (!dir) break;
      dir = dir.includes('/') ? dir.slice(0, dir.lastIndexOf('/')) : '';
    }
    if (!pkgDir) throw Error(`npm package ${name} is not installed (imported by ${args.importer})`);
    const pkg = packageJSON(pkgDir);
    const conditions = args.kind === 'require-call' ? ['browser', 'require', 'default'] : ['browser', 'import', 'module', 'default'];
    let target;
    if (pkg.exports !== undefined) {
      target = exported(pkg.exports, subpath, conditions);
      if (!target) throw Error(`${name} does not export ${subpath} for ${args.kind}`);
    } else if (subpath === '.') target = pkg.browser && typeof pkg.browser === 'string' ? pkg.browser : pkg.module || pkg.main || 'index.js';
    else target = subpath.slice(2);
    if (!target.startsWith('./') && !target.startsWith('../')) target = './' + target;
    const found = existing(normalize(`${pkgDir}/${target}`));
    if (!found) throw Error(`missing ${target} in npm package ${name}`);
    return { path: found, namespace: 'project' };
  };
  const plugin = { name: 'project-files', setup(build) {
    build.onResolve({ filter: /.*/ }, args => { try { return resolve(args); } catch (e) { return { errors: [{ text: String(e) }] }; } });
    build.onLoad({ filter: /.*/, namespace: 'empty' }, () => ({ contents: 'throw new Error("node:crypto unavailable in JavaScriptCore")', loader: 'js' }));
    build.onLoad({ filter: /.*/, namespace: 'project' }, args => {
      const contents = __read(args.path);
      if (contents == null) return { errors: [{ text: `unreadable or outside project: ${args.path}` }] };
      const ext = args.path.split('.').pop();
      const loader = ({ ts: 'ts', tsx: 'tsx', js: 'js', mjs: 'js', cjs: 'js', json: 'json' })[ext];
      if (!loader) return { errors: [{ text: `unsupported file type: ${args.path}` }] };
      return { contents, loader };
    });
  } };
  return {
    initialize: () => WebAssembly.compile(__wasm).then(module => { delete globalThis.__wasm; return esbuild.initialize({ wasmModule: module, worker: false }); }),
    compile: entry => esbuild.build({ entryPoints: [entry], bundle: true, write: false, platform: 'browser', format: 'iife', globalName: '__destino', target: 'es2022', logLevel: 'silent', metafile: true, plugins: [plugin], outfile: 'destino.js' }).then(
      result => JSON.stringify({ code: result.outputFiles[0].text, inputs: Object.keys(result.metafile.inputs), compatibilityShims: [...compatibilityShims] }),
      error => JSON.stringify({ errors: (error.errors || [{ text: String(error) }]).map(x => `${x.location ? `${x.location.file}:${x.location.line}: ` : ''}${x.text}`) })
    )
  };
})()
"""#
let api = context.evaluateScript(driver)!
if let exception { fputs("resolver bootstrap: \(exception)\n", stderr); exit(1) }

func settle(_ promise: JSValue?, stage: String) -> String {
    guard let promise, promise.isObject else { fputs("\(stage): no promise\n", stderr); exit(1) }
    var result: (Bool, String)?
    let success: @convention(block) (JSValue?) -> Void = { value in result = (true, value?.toString() ?? "") }
    let failure: @convention(block) (JSValue?) -> Void = { value in result = (false, value?.toString() ?? "JavaScript rejected") }
    promise.invokeMethod("then", withArguments: [JSValue(object: success, in: context) as Any, JSValue(object: failure, in: context) as Any])
    let deadline = Date().addingTimeInterval(120)
    while result == nil && exception == nil && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if let exception { fputs("\(stage): \(exception)\n", stderr); exit(1) }
    guard let result else { fputs("\(stage): timed out after 120 seconds\n", stderr); exit(1) }
    if result.0 { return result.1 }
    fputs("\(stage): \(result.1)\n", stderr); exit(1)
}

_ = settle(api.invokeMethod("initialize", withArguments: []), stage: "initialize esbuild-wasm")
let reply = settle(api.invokeMethod("compile", withArguments: [entry]), stage: "compile")
guard let data = reply.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    fputs("compiler returned invalid JSON\n", stderr); exit(1)
}
if let errors = object["errors"] as? [String] {
    fputs(errors.joined(separator: "\n") + "\n", stderr); exit(1)
}
guard let code = object["code"] as? String else { fputs("compiler returned no bundle\n", stderr); exit(1) }
if code.contains("require(\"node:") || code.contains("import(\"node:") {
    fputs("bundle contains residual Node imports\n", stderr); exit(1)
}
do {
    let bundle = code + "\nglobalThis.__destino = __destino;\n"
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bundle.write(to: output, atomically: true, encoding: .utf8)
    let inputs = object["inputs"] as? [String] ?? []
    let shims = object["compatibilityShims"] as? [String] ?? []
    let metadata: [String: Any] = ["inputs": inputs, "compatibilityShims": shims, "bytes": bundle.utf8.count]
    let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    try metadataData.write(to: URL(fileURLWithPath: output.path + ".metadata.json"), options: .atomic)
    print("compiled \(inputs.count) files into \(output.path) (\(bundle.utf8.count) bytes); compatibilityShims=\(shims)")
} catch {
    fputs("cannot write bundle: \(error)\n", stderr); exit(1)
}
