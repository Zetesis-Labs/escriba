import assert from "node:assert/strict";
import { cpSync, existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "vitest";
import { Library } from "../../../src/runtime/library/library";

test.each(["with space", "100% synthetic", "literal%20space", "biblioteca ñ", "hash#name"])("la biblioteca copiada a %s conserva notas, versiones y personas", async (segment) => {
  const temporary = mkdtempSync(join(tmpdir(), "escriba-path-"));
  const sourceRoot = join(temporary, "seed");
  const destinationRoot = join(temporary, segment);
  const escapedRoot = join(temporary, encodeURIComponent(segment));
  let library: Library | undefined;
  try {
    const audio = join(temporary, "synthetic.wav");
    writeFileSync(audio, "audio sintético");
    library = await Library.open(sourceRoot);
    const recording = await library.withStore((store) => store.import(audio)) as { id: string };
    const version = await library.mutate("version_save", {
      recordingId: recording.id,
      backend: "synthetic",
      transcript: { text: "Texto sintético", segments: [] },
    }) as { id: string };
    await library.mutate("recording_update", { id: recording.id, status: "done" });
    await library.addPersonVoice("Persona sintética", { speaker: "S", model: "synthetic", embedding: [1, 0] }, "muestra sintética");
    await library.close();
    library = undefined;

    mkdirSync(destinationRoot);
    cpSync(join(sourceRoot, "library.rocksdb"), join(destinationRoot, "library.rocksdb"), { recursive: true });
    library = await Library.open(destinationRoot);
    const detail = await library.recording(recording.id);
    assert.equal(library.index().recordings.length, 1);
    assert.equal(detail.status, "done");
    assert.ok(Array.isArray(detail.versions));
    assert.equal(detail.versions.length, 1);
    const restored = detail.versions[0];
    assert.ok(restored && typeof restored === "object" && !Array.isArray(restored));
    assert.equal(restored.id, version.id);
    assert.equal((await library.people()).length, 1);
    assert.equal(existsSync(escapedRoot), false, "Se creó una base hermana con la ruta escapada");
  } finally {
    await library?.close();
    rmSync(temporary, { recursive: true, force: true });
  }
});

test("rechaza una ruta con ? sin crear una base en la parte anterior", async () => {
  const temporary = mkdtempSync(join(tmpdir(), "escriba-path-"));
  try {
    const requested = join(temporary, "query?name");
    await assert.rejects(Library.open(requested), /\?/);
    assert.equal(existsSync(join(temporary, "query")), false);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
