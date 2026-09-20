import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";
const wasi = new WASI({ version: "preview1", args: ["probe"], env: {}, returnOnExit: true });
const wasm = await WebAssembly.compile(await readFile(process.argv[2]));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
process.exit(wasi.start(instance));
