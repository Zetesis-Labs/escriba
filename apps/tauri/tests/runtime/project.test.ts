import { afterEach, test } from "vitest";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { cp, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";

const bun = process.env.ESCRIBA_BUN || "bun";
const builder = fileURLToPath(new URL("../../runtime-host/project.ts", import.meta.url));
const vendor = fileURLToPath(new URL("../../node_modules", import.meta.url));
const folders: string[] = [];
const requireBuiltin = createRequire(import.meta.url);

function load(program: string) {
  return runInNewContext(`${program}\n;__recipe`, { require: requireBuiltin });
}

afterEach(async () => {
  await Promise.all(folders.splice(0).map((folder) => rm(folder, { recursive: true, force: true })));
});

async function project() {
  const folder = await mkdtemp(join("/private/tmp", "escriba-project-"));
  folders.push(folder);
  return folder;
}

function build(root: string) {
  return spawnSync(
    bun,
    ["--no-install", "--no-env-file", "--config=/dev/null", "-e",
      `import { buildProject } from ${JSON.stringify(builder)}; await buildProject(process.argv[1], process.argv[2]);`,
      root, vendor],
    { cwd: "/", encoding: "utf8", env: { ...process.env, BUN_BE_BUN: "1", TMPDIR: root } },
  );
}

test("empaqueta la ontología con dist y permite reconstruir sin borrar el artefacto anterior", async () => {
  const root = await project();
  await mkdir(join(root, "src"));
  await writeFile(join(root, "src/ontologias.ts"), 'export const ontologias = [{ id: "ejemplo.temas", name: "Temas", version: 1, migrations: [{ version: 1, sql: "DEFINE TABLE tema SCHEMAFULL;" }], collections: [] }];');
  const first = build(root);
  assert.equal(first.status, 0, first.stderr);
  const manifest = JSON.parse(await readFile(join(root, "dist/escriba.json"), "utf8"));
  assert.equal(manifest.ontologies, "ontologias.js");
  const program = await readFile(join(root, "dist/ontologias.js"), "utf8");
  const module = runInNewContext(`${program}\n;__ontologias`, { require: requireBuiltin });
  assert.equal(module.ontologias[0].id, "ejemplo.temas");
  assert.equal(build(root).status, 0);
  const rebuilt = await readFile(join(root, "dist/ontologias.js"), "utf8");
  await writeFile(join(root, "src/ontologias.ts"), 'import "./ausente.ts";');
  assert.notEqual(build(root).status, 0);
  assert.equal(await readFile(join(root, "dist/ontologias.js"), "utf8"), rebuilt);
});

test("construye un proyecto con dependencia local y deja paquetes autónomos", async () => {
  const root = await project();
  await mkdir(join(root, "src/recetas/sintetica"), { recursive: true });
  await mkdir(join(root, "dep"));
  await writeFile(join(root, "package.json"), JSON.stringify({
    name: "fixture", private: true, type: "module", dependencies: { "fixture-dep": "file:./dep" },
  }));
  await writeFile(join(root, "dep/package.json"), JSON.stringify({
    name: "fixture-dep", version: "1.0.0", main: "index.js", type: "module",
  }));
  await writeFile(join(root, "dep/index.js"), "export const answer = 42;\n");
  const install = spawnSync(bun, ["install", "--ignore-scripts", "--offline", `--cache-dir=${join(root, "cache")}`], {
    cwd: root, encoding: "utf8", env: { ...process.env, BUN_BE_BUN: "1", TMPDIR: root },
  });
  assert.equal(install.status, 0, install.stderr);
  await writeFile(join(root, "src/recetas/sintetica/receta.ts"),
    'import { answer } from "fixture-dep"; export async function flujo() { return answer; }\n');
  const result = build(root);
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(await readFile(join(root, "dist/escriba.json"), "utf8"));
  assert.deepEqual(manifest, {
    version: 1,
    recipes: [{ id: "sintetica", name: "sintetica", entry: "src/recetas/sintetica/receta.ts", file: "receta-0.js" }],
  });
  const program = await readFile(join(root, "dist/receta-0.js"), "utf8");
  const recipe = load(program);
  assert.equal(await recipe.flujo(), 42);
});

test("un error de compilación conserva íntegro el dist anterior", async () => {
  const root = await project();
  const recipe = join(root, "src/recetas/estable/receta.ts");
  await mkdir(join(root, "src/recetas/estable"), { recursive: true });
  await writeFile(recipe, "export const nombre = 'Estable';\n");
  const first = build(root);
  assert.equal(first.status, 0, first.stderr);
  const before = await readFile(join(root, "dist/receta-0.js"), "utf8");
  await writeFile(recipe, 'import "./ausente.ts"; export const nombre = "Rota";\n');
  const second = build(root);
  assert.notEqual(second.status, 0);
  assert.match(second.stderr, /No se pudo compilar src\/recetas\/estable\/receta.ts/);
  assert.match(second.stderr, /ausente.ts/);
  assert.equal(await readFile(join(root, "dist/receta-0.js"), "utf8"), before);
  assert.equal(JSON.parse(await readFile(join(root, "dist/escriba.json"), "utf8")).recipes[0].id, "estable");
});

test("admite recetas heredadas y usa las dependencias incluidas si faltan en el proyecto", async () => {
  const root = await project();
  await mkdir(join(root, "recetas/antigua"), { recursive: true });
  await mkdir(join(root, "personal"));
  await writeFile(join(root, "recetas/antigua/receta.js"),
    'import { z } from "zod"; import * as conectores from "@escriba/conectores"; export const nombre = z.string().parse("Antigua"); export const hayConectores = Object.keys(conectores).length > 0;\n');
  await writeFile(join(root, "personal/receta.ts"), "export const nombre = 'Personal';\n");
  await writeFile(join(root, "conectores.ts"), "export const destino = 'raíz';\n");
  const result = build(root);
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(await readFile(join(root, "dist/escriba.json"), "utf8"));
  assert.deepEqual(manifest.recipes.map((recipe: { id: string }) => recipe.id), ["code:personal", "antigua"]);
  assert.equal(manifest.connectors, "conectores.js");
  const code = await readFile(join(root, "dist/receta-1.js"), "utf8");
  const recipe = load(code);
  assert.equal(recipe.nombre, "Antigua");
  assert.equal(recipe.hayConectores, true);
});

test("usa el código del SDK instalado aunque un tsconfig heredado apunte a sus declaraciones", async () => {
  const root = await project();
  await mkdir(join(root, "src/recetas/sdk"), { recursive: true });
  await mkdir(join(root, "node_modules/@escriba"), { recursive: true });
  const sdk = fileURLToPath(new URL("../../src-tauri/vendor/node_modules/@escriba/conectores", import.meta.url));
  await cp(sdk, join(root, ".escriba/deps/conectores"), { recursive: true, dereference: true });
  await symlink(join(root, ".escriba/deps/conectores"), join(root, "node_modules/@escriba/conectores"));
  await writeFile(join(root, "tsconfig.json"), JSON.stringify({ compilerOptions: {
    paths: { "@escriba/conectores": ["./.escriba/deps/conectores/index.d.ts"] },
  } }));
  await writeFile(join(root, "src/recetas/sdk/receta.ts"),
    'import { createProgram } from "@escriba/conectores"; export const disponible = typeof createProgram === "function";\n');
  const result = build(root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(load(await readFile(join(root, "dist/receta-0.js"), "utf8")).disponible, true);
});

test("acepta APIs nativas de Bun y texto que menciona import sin cargar módulos", async () => {
  const root = await project();
  await mkdir(join(root, "src/recetas/ruta"), { recursive: true });
  await writeFile(join(root, "src/recetas/ruta/receta.ts"),
    'import { basename } from "node:path"; import { createHash } from "node:crypto"; export const texto = "import(x)"; export const base = basename("/uno/dos"); export const hash = createHash("sha256").update("a").digest("hex");\n');
  const result = build(root);
  assert.equal(result.status, 0, result.stderr);
  const code = await readFile(join(root, "dist/receta-0.js"), "utf8");
  const recipe = load(code);
  assert.equal(recipe.texto, "import(x)");
  assert.equal(recipe.base, "dos");
  assert.equal(recipe.hash, "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb");
});

test("la versión de Zod instalada por el proyecto prevalece sobre vendor", async () => {
  const root = await project();
  await mkdir(join(root, "src/recetas/propia"), { recursive: true });
  await mkdir(join(root, "local-zod"));
  await writeFile(join(root, "package.json"), JSON.stringify({
    name: "fixture", private: true, type: "module", dependencies: { zod: "file:./local-zod" },
  }));
  await writeFile(join(root, "local-zod/package.json"), JSON.stringify({
    name: "zod", version: "99.0.0", type: "module", exports: "./index.js",
  }));
  await writeFile(join(root, "local-zod/index.js"), "export const procedencia = 'proyecto';\n");
  const install = spawnSync(bun, ["install", "--ignore-scripts", "--offline", `--cache-dir=${join(root, "cache")}`], {
    cwd: root, encoding: "utf8", env: { ...process.env, BUN_BE_BUN: "1", TMPDIR: root },
  });
  assert.equal(install.status, 0, install.stderr);
  await writeFile(join(root, "src/recetas/propia/receta.ts"),
    'import { procedencia } from "zod"; export const nombre = procedencia;\n');
  const result = build(root);
  assert.equal(result.status, 0, result.stderr);
  const code = await readFile(join(root, "dist/receta-0.js"), "utf8");
  assert.equal(load(code).nombre, "proyecto");
});

test("rechaza IDs repetidos de carpetas nuevas y heredadas", async () => {
  const root = await project();
  await mkdir(join(root, "src/recetas/repetida"), { recursive: true });
  await mkdir(join(root, "recetas/repetida"), { recursive: true });
  await writeFile(join(root, "src/recetas/repetida/receta.ts"), "export const nombre='Nueva';\n");
  await writeFile(join(root, "recetas/repetida/receta.ts"), "export const nombre='Vieja';\n");
  const result = build(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /ID de receta repetido/);
  await assert.rejects(readFile(join(root, "dist/escriba.json")));
});

test("rechaza fuentes enlazadas fuera del proyecto", async () => {
  const root = await project();
  const outside = await project();
  await mkdir(join(root, "src/recetas/fuera"), { recursive: true });
  await writeFile(join(outside, "modulo.ts"), "export const secreto = 'fuera';\n");
  await symlink(join(outside, "modulo.ts"), join(root, "src/recetas/fuera/modulo.ts"));
  await writeFile(join(root, "src/recetas/fuera/receta.ts"),
    'import { secreto } from "./modulo.ts"; export const nombre = secreto;\n');
  const result = build(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /fuera del proyecto/);
});

test("reemplaza un dist declarado con rutas relativas y protege archivos ajenos", async () => {
  const root = await project();
  await mkdir(join(root, "src/recetas/nueva"), { recursive: true });
  await writeFile(join(root, "src/recetas/nueva/receta.ts"), "export const nombre='Nueva';\n");
  await mkdir(join(root, "dist/paquetes"), { recursive: true });
  await writeFile(join(root, "dist/paquetes/antigua.js"), "globalThis.__recipe={nombre:'Antigua'};\n");
  await writeFile(join(root, "dist/escriba.json"), JSON.stringify({
    version: 1, recipes: [{ id: "antigua", name: "Antigua", entry: "recetas/antigua/receta.ts", file: "paquetes/antigua.js" }],
  }));
  const result = build(root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(await readFile(join(root, "dist/escriba.json"), "utf8")).recipes[0].id, "nueva");
  await writeFile(join(root, "dist/mis-notas.txt"), "dato del usuario\n");
  const refused = build(root);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /archivos ajenos/);
  assert.equal(await readFile(join(root, "dist/mis-notas.txt"), "utf8"), "dato del usuario\n");
});
