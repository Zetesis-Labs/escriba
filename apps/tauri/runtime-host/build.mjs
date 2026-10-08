import { build } from "esbuild";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";
import { spawnSync } from "node:child_process";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(app, "../..");
export async function buildRuntime({
  output = resolve(
    app,
    "src-tauri/binaries/escriba-runtime-aarch64-apple-darwin",
  ),
  deno = "deno",
  target,
} = {}) {
  const options = {
    bundle: true,
    write: false,
    target: "es2022",
    nodePaths: [resolve(app, "node_modules")],
    alias: {
      "@escriba/conectores": resolve(root, "packages/conectores/src/index.ts"),
      zod: resolve(app, "node_modules/zod/index.js"),
    },
    logLevel: "warning",
  };
  const worker = await build({
    ...options,
    entryPoints: [resolve(app, "src/runtime/worker.ts")],
    platform: "browser",
    format: "iife",
  });
  const builtin = await readFile(
    resolve(root, "packages/conectores/dist/conectores.js"),
    "utf8",
  );
  const main = await build({
    ...options,
    entryPoints: [resolve(app, "runtime-host/main.ts")],
    platform: "neutral",
    format: "esm",
    external: ["node:async_hooks"],
    define: {
      __WORKER_SOURCE__: JSON.stringify(worker.outputFiles[0].text),
      __BUILTIN_PROGRAM__: JSON.stringify(builtin),
    },
  });
  const directory = resolve(app, "runtime-host/.build");
  await mkdir(directory, { recursive: true });
  await mkdir(dirname(output), { recursive: true });
  const entry = resolve(directory, "main.js");
  await writeFile(entry, main.outputFiles[0].contents);
  const args = [
    "compile",
    "--no-config",
    "--no-check",
    "--no-lock",
    "--no-npm",
    "--no-remote",
    "--no-prompt",
    "--v8-flags=--max-old-space-size=512",
    "--deny-read",
    "--deny-write",
    "--deny-net",
    "--deny-env",
    "--deny-run",
    "--deny-ffi",
    "--deny-sys",
    "--deny-import",
    "--output",
    output,
    ...(target ? ["--target", target] : []),
    entry,
  ];
  const result = spawnSync(deno, args, { stdio: "inherit" });
  if (result.status !== 0)
    throw Error(`Deno compile terminó con ${result.status}`);
  return output;
}
if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  await buildRuntime({ output: process.argv[2], target: process.argv[3] });
