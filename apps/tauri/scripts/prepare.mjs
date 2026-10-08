import { cp, mkdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
const app = fileURLToPath(new URL("..", import.meta.url));
const root = fileURLToPath(new URL("../../..", import.meta.url));
const vendor = join(app, "src-tauri/vendor/node_modules");
await mkdir(join(vendor, "@escriba"), { recursive: true });
for (const [source, target] of [
  [
    join(root, "Sources/EscribaJSC/Resources/conectores"),
    join(vendor, "@escriba/conectores"),
  ],
  [join(app, "node_modules/zod"), join(vendor, "zod")],
]) {
  await rm(target, { recursive: true, force: true });
  await cp(source, target, { recursive: true, dereference: true });
}
const triple =
  process.arch === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
await mkdir(join(app, "src-tauri/binaries"), { recursive: true });
await cp(
  join(app, `node_modules/@esbuild/darwin-${process.arch}/bin/esbuild`),
  join(app, `src-tauri/binaries/escriba-esbuild-${triple}`),
);

const { buildRuntime } = await import("../runtime-host/build.mjs");
await buildRuntime({ output: join(app, `src-tauri/binaries/escriba-runtime-${triple}`), target: triple });
