import { build } from "esbuild";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";
import { spawnSync } from "node:child_process";
import { buildBuiltinRecipes } from "./defaultRecipe.mjs";
import { bunTarget as bunTargetFor } from "./targets.mjs";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(app, "../..");
export async function buildRuntime({
  output = resolve(
    app,
    "src-tauri/binaries/escriba-runtime-aarch64-apple-darwin",
  ),
  bun = "bun",
  target,
} = {}) {
  const expected = (await readFile(resolve(app, "runtime-host/bun-version"), "utf8")).trim();
  const version = spawnSync(bun, ["--version"], { encoding: "utf8" });
  if (version.error) throw version.error;
  if (version.status !== 0 || version.stdout.trim() !== expected)
    throw Error(`Escriba necesita Bun ${expected} para compilar el runtime`);
  const options = {
    bundle: true,
    write: false,
    target: "es2022",
    nodePaths: [resolve(app, "node_modules")],
    alias: {
      "@escriba/conectores": resolve(root, "packages/conectores/src/index.ts"),
      zod: resolve(app, "node_modules/zod"),
    },
    logLevel: "warning",
  };
  const worker = await build({
    ...options,
    entryPoints: [resolve(app, "src/runtime/worker.ts")],
    platform: "browser",
    format: "iife",
    define: { __BUILTIN_RECIPES__: JSON.stringify(await buildBuiltinRecipes()) },
  });
  const builtin = await readFile(
    resolve(root, "packages/conectores/dist/conectores.js"),
    "utf8",
  );
  const main = await build({
    ...options,
    entryPoints: [resolve(app, "runtime-host/main.ts")],
    platform: "node",
    format: "esm",
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
  const bunTarget = target ? bunTargetFor(target) : undefined;
  const result = spawnSync(bun, [
    "build", "--compile", "--no-compile-autoload-dotenv", "--no-compile-autoload-bunfig",
    "--compile-exec-argv=--no-install", entry, "--outfile", output,
    ...(bunTarget ? [`--target=${bunTarget}`] : []),
  ], { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(`Bun build terminó con ${result.status}`);
  if (process.platform === "darwin") {
    const signed = spawnSync("codesign", ["--force", "--sign", "-", output], { stdio: "inherit" });
    if (signed.error) throw signed.error;
    if (signed.status !== 0) throw Error(`La firma del runtime terminó con ${signed.status}`);
  }
  return output;
}
if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  await buildRuntime({ output: process.argv[2], target: process.argv[3] });
