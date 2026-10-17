import { access, cp, mkdir, rm, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { prepareSurrealdb } from "./prepare-surrealdb.mjs";
import { hostTriple, surrealNative, typescriptPackage } from "../runtime-host/targets.mjs";
const app = fileURLToPath(new URL("..", import.meta.url));
const root = fileURLToPath(new URL("../../..", import.meta.url));
const vendor = join(app, "src-tauri/vendor/node_modules");
await mkdir(join(vendor, "@escriba"), { recursive: true });
for (const [source, target] of [
  [
    join(root, "packages/conectores/bundle"),
    join(vendor, "@escriba/conectores"),
  ],
  [join(app, "node_modules/zod"), join(vendor, "zod")],
  [
    join(app, "runtime-host/toolchain/node_modules", typescriptPackage(process.platform, process.arch)),
    join(vendor, "typescript"),
  ],
]) {
  await rm(target, { recursive: true, force: true });
  await cp(source, target, { recursive: true, dereference: true });
}
for (const file of ["lib.d.ts", process.platform === "win32" ? "tsc.exe" : "tsc"]) {
  await access(join(vendor, "typescript/lib", file));
}
for (const dependency of ["@types/bun", "bun-types", "@types/node", "undici-types"]) {
  const target = join(vendor, dependency);
  await rm(target, { recursive: true, force: true });
  await cp(join(app, "runtime-host/toolchain/node_modules", dependency), target, { recursive: true, dereference: true });
  if (process.platform === "win32") {
    const manifest = join(target, "package.json");
    const value = JSON.parse(await readFile(manifest, "utf8"));
    // All types live at the root; Bun on Windows fails copying their nested file dependencies.
    for (const name of ["bun-types", "@types/node", "undici-types"]) {
      if (value.dependencies) delete value.dependencies[name];
    }
    await writeFile(manifest, `${JSON.stringify(value, null, 2)}\n`);
  }
}
await prepareSurrealdb(app, vendor);
const surreal = surrealNative(process.platform, process.arch);
await mkdir(join(app, "src-tauri/surreal"), { recursive: true });
await cp(join(app, "node_modules", surreal.package, surreal.file), join(app, "src-tauri/surreal", surreal.file));
const triple = hostTriple(process.platform, process.arch);
await mkdir(join(app, "src-tauri/binaries"), { recursive: true });

const { buildRuntime } = await import("../runtime-host/build.mjs");
await buildRuntime({ output: join(app, `src-tauri/binaries/escriba-runtime-${triple}${process.platform === "win32" ? ".exe" : ""}`), target: triple });
