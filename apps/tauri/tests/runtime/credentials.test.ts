import { test } from "vitest";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { credentialPath, fileCredentials, memoryCredentials } from "../../src/runtime/credentials";

test("una credencial se guarda recortada en un fichero privado y vacía se retira", async () => {
  const root = await mkdtemp(join(tmpdir(), "escriba-secrets-"));
  try {
    const store = fileCredentials(root);
    assert.equal(await store.read("notion"), undefined);
    await store.save("notion", "  token-sintético \n");
    assert.equal(await readFile(credentialPath(root, "notion"), "utf8"), "token-sintético");
    assert.equal((await stat(credentialPath(root, "notion"))).mode & 0o777, 0o600);
    assert.equal((await stat(join(root, "secrets"))).mode & 0o777, 0o700);
    assert.equal(await store.read("notion"), "token-sintético");
    await store.save("notion", "   ");
    assert.equal(await store.read("notion"), undefined);
    await assert.rejects(store.save("../escape", "x"), /Identificador inválido/);
    await assert.rejects(store.read("con espacios"), /Identificador inválido/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("el almacén en memoria sigue las mismas reglas", async () => {
  const store = memoryCredentials({ a: "uno" });
  assert.equal(await store.read("a"), "uno");
  await store.save("a", "");
  assert.equal(await store.read("a"), undefined);
  await assert.rejects(store.read(".."), /Identificador inválido/);
});
