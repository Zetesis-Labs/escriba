// Ejecuta un plugin de Escriba fuera de la app, con el host servido contra una carpeta:
//   node scripts/run-plugin.mjs plugin.wasm carpeta < peticion.json
// Las llamadas http no están disponibles en este arnés (son síncronas en wasm).
import { readFile } from "node:fs/promises";
import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync, existsSync } from "node:fs";
import { WASI } from "node:wasi";
import { join, dirname, relative } from "node:path";

const [wasmPath, folder = "."] = process.argv.slice(2);
const target = (p) => join(folder, p);

function serve(req) {
  switch (req.op) {
    case "log": console.error("[plugin]", req.message); return {};
    case "read": return existsSync(target(req.path)) ? { contents: readFileSync(target(req.path), "utf8") } : {};
    case "list": {
      const out = [];
      const walk = (dir) => { if (!existsSync(dir)) return; for (const e of readdirSync(dir, { withFileTypes: true })) { const f = join(dir, e.name); if (e.isDirectory()) walk(f); else if (e.name.endsWith(".md")) out.push(relative(folder, f)); } };
      walk(folder);
      return { paths: out.sort() };
    }
    case "write": mkdirSync(dirname(target(req.path)), { recursive: true }); writeFileSync(target(req.path), req.contents ?? ""); return {};
    case "remove": rmSync(target(req.path), { force: true }); return {};
    default: return { error: `operación ${req.op} no disponible en el arnés` };
  }
}

let pending = Buffer.from(readFileSync(0));
let response = null;
let memory;
const wasi = new WASI({ version: "preview1", args: ["plugin"], env: { TZ: "UTC" }, preopens: { "/usr/share/zoneinfo": "/usr/share/zoneinfo" } });
const module = await WebAssembly.compile(await readFile(wasmPath));
const instance = await WebAssembly.instantiate(module, {
  ...wasi.getImportObject(),
  escriba: {
    call(ptr, len) {
      const req = JSON.parse(Buffer.from(memory.buffer, ptr, len).toString("utf8"));
      let res;
      try { res = serve(req); } catch (e) { res = { error: String(e) }; }
      pending = Buffer.from(JSON.stringify(res));
      return pending.length;
    },
    take(ptr, cap) {
      const n = Math.min(cap, pending.length);
      new Uint8Array(memory.buffer, ptr, n).set(pending.subarray(0, n));
      pending = Buffer.alloc(0);
      return n;
    },
    respond(ptr, len) {
      response = Buffer.from(memory.buffer, ptr, len).toString("utf8");
    },
  },
});
memory = instance.exports.memory;
wasi.initialize(instance);
const started = Date.now();
const code = instance.exports.escriba_handle(pending.length);
console.error(`escriba_handle → ${code} en ${Date.now() - started} ms; memoria ${(memory.buffer.byteLength / 1048576).toFixed(1)} MB`);
console.log(response ?? "");
