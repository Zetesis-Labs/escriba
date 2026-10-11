import { test } from "vitest";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { prepareSurrealdb } from "../../scripts/prepare-surrealdb.mjs";

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const app = join(root, "apps/tauri");

test("el SDK oficial se instala sin red y compila un proyecto externo con ontología", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "escriba-sdk-offline-"));
  try {
    const modules = join(temporary, "vendor/node_modules");
    const project = join(temporary, "project");
    await mkdir(join(modules, "@escriba/conectores"), { recursive: true });
    await mkdir(join(modules, "zod"));
    await prepareSurrealdb(app, modules);
    const types = await readFile(join(modules, "surrealdb/index.d.ts"), "utf8");
    assert.match(types, /declare class UUID \{/);
    assert.match(types, /static parse\(uuid: string\): UUID;/);
    assert.match(types, /equals\(other: UUID\): boolean;/);
    assert.match(types, /type Replacer = \(v: any\) => unknown;/);
    await cp(join(root, "examples/conocimiento"), project, { recursive: true });
    await mkdir(join(project, ".escriba/deps"), { recursive: true });
    await cp(join(modules, "surrealdb"), join(project, ".escriba/deps/surrealdb"), { recursive: true });
    await cp(join(root, "recetas/escriba-recetas.d.ts"), join(project, "escriba-recetas.d.ts"));

    const install = spawnSync("bun", ["install", "--offline", "--ignore-scripts"], {
      cwd: project, encoding: "utf8", env: { ...process.env, BUN_INSTALL_CACHE_DIR: join(temporary, "cache") },
    });
    assert.equal(install.status, 0, install.stderr);
    const sdk = spawnSync("bun", ["-e", `import { CborCodec, RecordId } from "surrealdb";
      const id = new RecordId("reunion", "sintetica");
      const decoded = CborCodec.DEFAULT.decode(CborCodec.DEFAULT.encode({ id }));
      if (!(decoded.id instanceof RecordId)) throw Error("RecordId perdió su tipo");`], {
      cwd: project, encoding: "utf8",
    });
    assert.equal(sdk.status, 0, sdk.stderr);
    const typecheck = spawnSync(process.execPath, [join(app, "node_modules/typescript/bin/tsc"), "-p", project], { encoding: "utf8" });
    assert.equal(typecheck.status, 0, typecheck.stdout + typecheck.stderr);
    const build = spawnSync("bun", ["-e", `import {buildProject} from ${JSON.stringify(join(app, "runtime-host/project.ts"))}; await buildProject(process.argv[1],process.argv[2])`, project, join(temporary, "vendor")], {
      cwd: root, encoding: "utf8", env: { ...process.env, BUN_INSTALL_CACHE_DIR: join(temporary, "cache") },
    });
    assert.equal(build.status, 0, build.stdout + build.stderr);
    const manifest = JSON.parse(await readFile(join(project, "dist/escriba.json"), "utf8"));
    assert.equal(manifest.recipes.length, 1);
    assert.equal(manifest.ontologies, "ontologias.js");
    const bundle = await readFile(join(project, "dist/receta-0.js"), "utf8");
    assert.match(bundle, /RecordId/);
    assert.match(await readFile(join(project, ".escriba/deps/surrealdb/package.json"), "utf8"), /"version":"2\.1\.1"/);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
