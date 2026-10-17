import { afterEach, test } from "vitest";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, toNamespacedPath } from "node:path";
import { projectCanonicalPath } from "../../runtime-host/project-path";

const folders: string[] = [];
afterEach(async () => {
  await Promise.all(folders.splice(0).map((folder) => rm(folder, { recursive: true, force: true })));
});

async function folder() {
  const root = await mkdtemp(join(await realpath(tmpdir()), "escriba-canonical-"));
  folders.push(root);
  return root;
}

const denied = async (): Promise<string> => { throw Object.assign(Error("realpath denegado"), { code: "EPERM" }); };

test.runIf(process.platform === "win32")("resuelve rutas dentro del proyecto cuando AppContainer deniega realpath", async () => {
  const root = await folder();
  await mkdir(join(root, "src"));
  await writeFile(join(root, "src/receta.ts"), "export const valor = 1;");
  const canonical = projectCanonicalPath([root], denied);
  assert.equal(await canonical(toNamespacedPath(root)), root);
  assert.equal(await canonical(toNamespacedPath(join(root, "src/receta.ts"))), join(root, "src/receta.ts"));
  await assert.rejects(canonical(join(root, "ausente.ts")), { code: "ENOENT" });
});

test.runIf(process.platform === "win32")("sigue uniones internas y rechaza escapes a una carpeta vecina", async () => {
  const root = await folder();
  const outside = `${root}-vecina`;
  folders.push(outside);
  await mkdir(join(root, "real"));
  await mkdir(outside);
  await writeFile(join(root, "real/modulo.ts"), "export const valor = 1;");
  await writeFile(join(outside, "secreto.ts"), "export const valor = 2;");
  await symlink(join(root, "real"), join(root, "interna"), "junction");
  await symlink(outside, join(root, "externa"), "junction");
  const canonical = projectCanonicalPath([root], denied);
  assert.equal(await canonical(join(root, "interna/modulo.ts")), join(root, "real/modulo.ts"));
  await assert.rejects(canonical(join(root, "externa/secreto.ts")), /fuera del proyecto/);
  await assert.rejects(canonical(join(outside, "secreto.ts")), /fuera del proyecto/);
});

test.runIf(process.platform === "win32")("admite dependencias en otra raíz y limita los ciclos de uniones", async () => {
  const root = await folder();
  const vendor = await folder();
  await mkdir(join(vendor, "paquete"));
  await writeFile(join(vendor, "paquete/index.js"), "export const valor = 1;");
  await symlink(join(vendor, "paquete"), join(root, "dependencia"), "junction");
  await symlink(root, join(root, "ciclo"), "junction");
  const canonical = projectCanonicalPath([root, vendor], denied);
  assert.equal(await canonical(join(root, "dependencia/index.js")), join(vendor, "paquete/index.js"));
  await assert.rejects(canonical(join(root, ...Array<string>(42).fill("ciclo"))), /Demasiados enlaces/);
});

test("propaga los errores de realpath que no son el fallo de AppContainer", async () => {
  const root = await folder();
  const failure = Object.assign(Error("sin acceso"), { code: "EACCES" });
  const canonical = projectCanonicalPath([root], async () => { throw failure; });
  await assert.rejects(canonical(root), (error) => error === failure);
});
