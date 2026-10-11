import { expect, test } from "vitest";
import { createDemoDraftHost } from "../../src/library/demoDraftHost";
import type { Recording } from "../../src/types";

const recording = (id: string): Recording => ({
  id,
  title: "Original",
  createdAt: "2026-10-11T10:00:00Z",
  source: "audio-sintetico.m4a",
  audioPath: null,
  duration: 10,
  status: "done",
  currentVersionId: "v1",
  versions: [{ id: "v1", createdAt: "2026-10-11T10:01:00Z", backend: "local", transcript: { text: "Texto sintético", segments: [] } }],
  publications: [],
});

test("el host demo recupera borrador, confirma una versión y reutiliza el recibo", async () => {
  let source = recording("demo-draft-test-1");
  const host = createDemoDraftHost(() => source, (updated) => { source = updated; });
  const begun = await host.begin(source.id);
  expect((await host.get(source.id))?.id).toBe(begun.id);
  const saved = await host.save(source.id, begun.id, 0, { ...begun.content, title: "Corregido" });
  expect(saved.revision).toBe(1);
  const result = await host.commit(source.id, begun.id, 1);
  expect(result.created).toBe(true);
  expect(source.versions).toHaveLength(2);
  expect(source.currentVersionId).toBe(result.version.id);
  expect(source.title).toBe("Corregido");
  expect(await host.get(source.id)).toBeNull();
  expect(await host.commit(source.id, begun.id, 1)).toEqual(result);
  expect(source.versions).toHaveLength(2);
});

test("el conflicto conserva el borrador y permite descartarlo", async () => {
  let source = recording("demo-draft-test-2");
  const host = createDemoDraftHost(() => source, () => {});
  const begun = await host.begin(source.id);
  source = { ...source, title: "Cambio externo" };
  await expect(host.save(source.id, begun.id, 0, begun.content)).rejects.toThrow("versión de origen cambió");
  expect((await host.get(source.id))?.id).toBe(begun.id);
  await host.discard(source.id, begun.id, 0);
  expect(await host.get(source.id)).toBeNull();
});

test("confirmar sin cambios no añade una versión", async () => {
  const source = recording("demo-draft-test-3");
  const host = createDemoDraftHost(() => source, () => { throw Error("No debería publicar"); });
  const begun = await host.begin(source.id);
  const result = await host.commit(source.id, begun.id, 0);
  expect(result.created).toBe(false);
  expect(result.version.id).toBe("v1");
  expect(source.versions).toHaveLength(1);
});
