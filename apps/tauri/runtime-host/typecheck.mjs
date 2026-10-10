import { spawnSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const host = dirname(fileURLToPath(import.meta.url));
const app = resolve(host, "..");
const generated = resolve(host, ".build/typecheck");
await mkdir(generated, { recursive: true });
const config = resolve(generated, "tsconfig.json");
await writeFile(
  config,
  JSON.stringify(
    {
      extends: resolve(app, "tsconfig.json"),
      compilerOptions: { noEmit: true, types: ["node"] },
      include: [resolve(host, "main.ts")],
    },
    null,
    2,
  ),
);
const result = spawnSync(
  process.execPath,
  [resolve(app, "node_modules/typescript/bin/tsc"), "--project", config],
  { stdio: "inherit" },
);
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
