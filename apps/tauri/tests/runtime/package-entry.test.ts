import { test } from "vitest";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { packageEntry } from "../../runtime-host/package-entry";

const vendor = fileURLToPath(new URL("../../src-tauri/vendor", import.meta.url));

test("el AI SDK y Zod se resuelven por sus exports desde el vendor", () => {
  assert.equal(packageEntry("ai", vendor), join(vendor, "node_modules/ai/dist/index.js"));
  assert.equal(packageEntry("@ai-sdk/provider", vendor), join(vendor, "node_modules/@ai-sdk/provider/dist/index.js"));
  assert.equal(packageEntry("zod", vendor), join(vendor, "node_modules/zod/index.js"));
  assert.equal(packageEntry("zod/v4", vendor), join(vendor, "node_modules/zod/v4/index.js"));
  assert.equal(packageEntry("json-schema", vendor), join(vendor, "node_modules/json-schema/lib/validate.js"));
});

test("busca en los node_modules de cada carpeta hacia arriba y prefiere el del proyecto", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "escriba-entry-")));
  try {
    await mkdir(join(root, "node_modules/pkg/lib"), { recursive: true });
    await mkdir(join(root, "src/a/b"), { recursive: true });
    await writeFile(join(root, "node_modules/pkg/package.json"), JSON.stringify({ exports: { ".": { types: "./x.d.ts", import: "./lib/main.js" }, "./extra/*": "./lib/*.js" } }));
    await writeFile(join(root, "node_modules/pkg/lib/main.js"), "");
    await writeFile(join(root, "node_modules/pkg/lib/uno.js"), "");
    assert.equal(packageEntry("pkg", join(root, "src/a/b")), join(root, "node_modules/pkg/lib/main.js"));
    assert.equal(packageEntry("pkg/extra/uno", join(root, "src/a/b")), join(root, "node_modules/pkg/lib/uno.js"));
    assert.throws(() => packageEntry("pkg/privado", root), /no exporta \.\/privado/);
    assert.equal(packageEntry("ausente", join(root, "src")), undefined);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
