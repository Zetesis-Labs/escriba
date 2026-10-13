import { test } from "vitest";
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Persistence } from "../../../src/runtime/library/persistence";
import { Store, discardedRecord } from "../../../src/runtime/library/store";
import { readLibraryData } from "../../../src/runtime/library/model";
import { canonical } from "../../../src/runtime/library/json";
import { arr, obj, str } from "./fixture";

const source = process.env.ESCRIBA_VERIFY_LIBRARY_COPY;

test.skipIf(!source)("verifica la compatibilidad de una copia sin mostrar contenido", async () => {
  const temporary = mkdtempSync(join(tmpdir(), "escriba-real-"));
  chmodSync(temporary, 0o700);
  try {
    cpSync(source!, join(temporary, "library.rocksdb"), { recursive: true });
    const database = await Persistence.open(join(temporary, "library.rocksdb"));
    const before = await database.load();
    assert.ok(before, "La copia no contiene biblioteca");
    const typed = readLibraryData(before);
    assert.equal(canonical(typed), canonical(before), "La representación tipada cambió campos guardados");
    const recordings = typed.recordings.length;
    const versions = typed.recordings.reduce((sum, record) => sum + (record.versions?.length ?? 0), 0);
    await database.close();
    const store = await Store.open(temporary, { audioCleanup: false });
    try {
      const jobs = await store.jobs();
      assert.equal(store.data.recordings.length, recordings);
      assert.equal(store.data.recordings.reduce((sum, record) => sum + (record.versions?.length ?? 0), 0), versions);
      for (const original of arr(obj(before).recordings)) {
        const full = await store.recording(str(original.id));
        if (original.status === "discarded") {
          assert.equal(arr(original.versions).length, 0);
          assert.equal(arr(original.publications).length, 0);
          assert.deepEqual(full, discardedRecord(original), "La lápida cambió su identidad");
          continue;
        }
        assert.equal(canonical(full.versions), canonical(original.versions), "El índice alteró versiones guardadas");
        assert.equal(canonical(full.publications), canonical(original.publications), "El índice alteró recibos guardados");
      }
      const context = await store.runtimeContext();
      assert.ok(arr(context.recipes).length >= 1);
      const first = store.data.recordings.find((record) => record.status !== "discarded");
      if (first) {
        const detail = await store.recording(first.id);
        assert.equal(detail.id, first.id);
      }
      console.error(`Compatibilidad confirmada: ${recordings} grabaciones, ${versions} versiones, ${jobs.length} trabajos; contenido no mostrado`);
    } finally {
      await store.close();
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}, 120000);
