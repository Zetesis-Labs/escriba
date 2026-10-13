import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import type { Store } from "../../../src/runtime/library/store";
import { arr, obj, str, workspace, reopen, type Workspace } from "./fixture";

let space: Workspace;
beforeEach(async () => {
  space = await workspace();
});
afterEach(async () => {
  await space.dispose();
});
const voice = (speaker: string, embedding: number[], model = "m") => ({ speaker, model, embedding });

test("un borrador duradero acumula cambios sin crear versiones", async () => {
  const audio = space.path("sintetico.wav");
  writeFileSync(audio, "audio sintetico");
  let store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  const version = await store.mutate("version_save", { recordingId: key, transcript: { text: "original", segments: [] } });
  const draft = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  const content = obj(draft.content);
  content.title = "Editado";
  obj(content.transcript).text = "corregido";
  let saved = obj(await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: draft.revision, content }));
  const secondContent = obj(saved.content);
  secondContent.data = { segundo: true };
  saved = obj(await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 1, content: secondContent }));
  assert.equal(saved.revision, 2);
  store = await reopen(space, store);
  assert.deepEqual(await store.mutate("note_draft_get", { recordingId: key }), saved);
  assert.deepEqual((await store.recording(key)).versions, [version]);
  assert.ok(!JSON.stringify(store.indexJson()).includes("corregido"));
  assert.ok(!JSON.stringify(await store.snapshot()).includes("corregido"));
  assert.ok(!JSON.stringify(await store.runtimeContext(key)).includes("corregido"));
});

test("confirmar un borrador crea una versión atómica y es idempotente", async () => {
  const audio = space.path("sintetico.wav");
  writeFileSync(audio, "audio sintetico");
  let store = await space.open();
  const record = obj(await store.import(audio));
  const key = str(record.id);
  const original = await store.mutate("version_save", { recordingId: key, recipeId: "sintetica", inputs: { uno: 1 }, transcript: { text: "original", segments: [] }, digest: { title: "Original", summary: "Resumen", tags: [] }, data: { uno: 1 } });
  const draft = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  const content = obj(draft.content);
  content.title = "Editado";
  obj(content.transcript).text = "corregido";
  obj(content.digest).summary = "Resumen editado";
  content.data = { dos: 2 };
  const saved = obj(await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content }));
  const params = { recordingId: key, draftId: draft.id, expectedRevision: saved.revision };
  const result = obj(await store.mutate("note_draft_commit", params));
  assert.equal(result.created, true);
  const version = obj(result.version);
  assert.equal(obj(version.digest).title, "Editado");
  assert.equal(obj(version.transcript).text, "corregido");
  assert.deepEqual(version.inputs, { uno: 1 });
  assert.equal(version.recipeId, "sintetica");
  assert.deepEqual(version.data, { dos: 2 });
  store = await reopen(space, store);
  assert.deepEqual(await store.mutate("note_draft_commit", params), result);
  const detail = await store.recording(key);
  assert.equal(arr(detail.versions).length, 2);
  assert.deepEqual(arr(detail.versions)[0], original);
  assert.equal(detail.audioPath, record.audioPath);
  assert.equal(await store.mutate("note_draft_get", { recordingId: key }), null);
  assert.ok(existsSync(audio));
});

async function noteDraftFixture() {
  const audio = space.path("sintetico.wav");
  writeFileSync(audio, "audio sintetico");
  const store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  await store.mutate("version_save", { recordingId: key, transcript: { text: "original", segments: [{ start: 0, end: 1, text: "original", speaker: "A" }] } });
  const draft = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  return { store, key, draft };
}

test("un borrador rechaza carreras y base modificada sin perder ediciones", async () => {
  const { store, key, draft } = await noteDraftFixture();
  const content = obj(draft.content);
  content.title = "Edición local";
  const params = { recordingId: key, draftId: draft.id, expectedRevision: 0, content };
  const saved = await store.mutate("note_draft_save", params);
  await assert.rejects(store.mutate("note_draft_save", params));
  await assert.rejects(store.mutate("note_draft_commit", params));
  await assert.rejects(store.mutate("note_draft_discard", params));
  await store.mutate("version_update", { recordingId: key, versionId: draft.baseVersionId, data: { externo: true } });
  const latest = { recordingId: key, draftId: draft.id, expectedRevision: 1, content };
  await assert.rejects(store.mutate("note_draft_commit", latest));
  await assert.rejects(store.mutate("note_draft_save", latest));
  assert.deepEqual(await store.mutate("note_draft_get", { recordingId: key }), saved);
  await store.mutate("note_draft_discard", latest);
  assert.equal(arr((await store.recording(key)).versions).length, 1);
});

test("un borrador sin cambios se cierra sin versión y descartada no resucita", async () => {
  const { store, key, draft } = await noteDraftFixture();
  const params = { recordingId: key, draftId: draft.id, expectedRevision: 0 };
  const original = await store.recording(key);
  const result = obj(await store.mutate("note_draft_commit", params));
  assert.equal(result.created, false);
  assert.deepEqual(await store.recording(key), original);
  assert.deepEqual(await store.mutate("note_draft_commit", params), result);
  const again = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  await store.mutate("recording_discard", { id: key });
  const reopened = await reopen(space, store);
  for (const method of ["note_draft_begin", "note_draft_get", "note_draft_save", "note_draft_commit"])
    await assert.rejects(reopened.mutate(method, { recordingId: key, draftId: again.id, expectedRevision: 0, content: again.content }));
});

test("un borrador rechaza tiempos y tipos inválidos sin reemplazarlo", async () => {
  const { store, key, draft } = await noteDraftFixture();
  for (const invalid of [4, false, null, []])
    await assert.rejects(store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content: invalid }));
  for (const bad of [{ start: 2, end: 1, text: "invalido" }, { start: -1, end: 1, text: "invalido" }, { start: 0, end: 1, text: false }]) {
    const content = JSON.parse(JSON.stringify(draft.content)) as Record<string, unknown>;
    (content.transcript as Record<string, unknown>).segments = [bad];
    await assert.rejects(store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content: content as never }));
  }
  assert.deepEqual(await store.mutate("note_draft_get", { recordingId: key }), draft);
});

test("un borrador confirmado falla atómicamente y permite reintentar", async () => {
  const { store, key, draft } = await noteDraftFixture();
  const original = await store.recording(key);
  const content = obj(draft.content);
  content.title = "Cambio";
  const saved = await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content });
  await store.database.queryTest("DEFINE FIELD OVERWRITE payload ON TABLE note_draft_receipt TYPE object ASSERT false");
  const params = { recordingId: key, draftId: draft.id, expectedRevision: 1 };
  await assert.rejects(store.mutate("note_draft_commit", params));
  assert.deepEqual(await store.recording(key), original);
  assert.deepEqual(await store.mutate("note_draft_get", { recordingId: key }), saved);
  await store.database.queryTest("DEFINE FIELD OVERWRITE payload ON TABLE note_draft_receipt TYPE object");
  assert.equal(obj(await store.mutate("note_draft_commit", params)).created, true);
  assert.deepEqual(arr((await store.recording(key)).versions)[0], arr(original.versions)[0]);
});

test("un borrador asigna fragmentos sin aprender huellas ambiguas", async () => {
  const { store, key, draft: initial } = await noteDraftFixture();
  await store.mutate("note_draft_discard", { recordingId: key, draftId: initial.id, expectedRevision: 0 });
  const transcript = await store.recognizeTranscription(key, { text: "uno dos tres", segments: [{ start: 0, end: 1, text: "uno", speaker: "A" }, { start: 1, end: 2, text: "dos", speaker: "A" }, { start: 2, end: 3, text: "tres", speaker: "B" }], voices: [voice("A", [1, 0]), voice("B", [0, 1])] });
  const source = obj(await store.mutate("version_save", { recordingId: key, transcript }));
  let draft = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  let content = obj(draft.content);
  arr(obj(content.transcript).segments)[0]!.speaker = "Persona";
  await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content });
  let committed = obj(await store.mutate("note_draft_commit", { recordingId: key, draftId: draft.id, expectedRevision: 1 }));
  const copied = await store.database.versionVoices(str(obj(committed.version).id));
  assert.equal(copied.length, 1);
  assert.equal(copied[0]!.speaker, "B");
  assert.deepEqual(await store.knownVoices(), []);
  assert.equal((await store.database.versionVoices(str(source.id))).length, 2);
  assert.ok(!JSON.stringify(committed).includes("embedding"));
  await store.mutate("version_select", { recordingId: key, versionId: source.id });
  draft = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  content = obj(draft.content);
  arr(obj(content.transcript).segments)[0]!.speaker = "B";
  await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content });
  committed = obj(await store.mutate("note_draft_commit", { recordingId: key, draftId: draft.id, expectedRevision: 1 }));
  assert.equal(obj(committed.version).hasVoices, false);
});

test("un borrador legacy sin versión vigente usa la última por fecha sin duplicarla", async () => {
  for (const currentId of [null, "inexistente"]) {
    const local = await workspace();
    try {
      const store = await local.open();
      const legacy = obj(await store.dataJson());
      const record: Record<string, unknown> = { id: "legacy", title: "Original", status: "done", currentVersionId: currentId, versions: [{ id: "reciente", createdAt: "2026-02-01", transcript: { text: "reciente", segments: [] } }, { id: "antigua", createdAt: "2026-01-01", transcript: { text: "antigua", segments: [] } }], publications: [] };
      if (currentId === null) delete record.currentVersionId;
      legacy.recordings = [record as never];
      await store.replace(legacy);
      const before = await store.recording("legacy");
      let draft = obj(await store.mutate("note_draft_begin", { recordingId: "legacy" }));
      assert.equal(draft.baseVersionId, "reciente");
      let params = { recordingId: "legacy", draftId: draft.id, expectedRevision: 0 };
      let result = obj(await store.mutate("note_draft_commit", params));
      assert.equal(result.created, false);
      assert.equal(obj(result.version).id, "reciente");
      assert.deepEqual(await store.mutate("note_draft_commit", params), result);
      assert.deepEqual(await store.recording("legacy"), before);
      draft = obj(await store.mutate("note_draft_begin", { recordingId: "legacy" }));
      const content = obj(draft.content);
      content.title = "Título manual";
      await store.mutate("note_draft_save", { recordingId: "legacy", draftId: draft.id, expectedRevision: 0, content });
      params = { recordingId: "legacy", draftId: draft.id, expectedRevision: 1 };
      result = obj(await store.mutate("note_draft_commit", params));
      assert.equal(result.created, true);
      assert.equal(obj(obj(result.version).transcript).text, "reciente");
      assert.deepEqual(await store.mutate("note_draft_commit", params), result);
      const detail = await store.recording("legacy");
      assert.equal(arr(detail.versions).length, 3);
      assert.deepEqual(arr(detail.versions)[0], arr(before.versions)[0]);
      assert.deepEqual(arr(detail.versions)[1], arr(before.versions)[1]);
    } finally {
      await local.dispose();
    }
  }
});

test("un borrador conserva el título manual tras regenerar el resumen", async () => {
  const { store, key, draft } = await noteDraftFixture();
  const content = obj(draft.content);
  content.title = "Título manual";
  await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content });
  const result = obj(await store.mutate("note_draft_commit", { recordingId: key, draftId: draft.id, expectedRevision: 1 }));
  await store.mutate("version_update", { recordingId: key, versionId: obj(result.version).id, digest: { title: "Título regenerado", summary: "Resumen nuevo", tags: [] } });
  const again = obj(await store.mutate("note_draft_begin", { recordingId: key }));
  assert.equal(obj(again.content).title, "Título manual");
  assert.equal(obj(obj(again.content).digest).summary, "Resumen nuevo");
  await store.mutate("note_draft_save", { recordingId: key, draftId: again.id, expectedRevision: 0, content: again.content });
  const second = obj(await store.mutate("note_draft_commit", { recordingId: key, draftId: again.id, expectedRevision: 1 }));
  assert.equal(second.created, false);
});

test("el color de persona se conserva al añadir huellas, reabrir y renombrar", async () => {
  let store: Store = await space.open();
  const sample = voice("S", [1, 0]);
  await store.addPersonVoice("Ana", sample, "sintetico");
  await store.setPersonColor("Ana", "#Ab12Cd");
  await store.addPersonVoice("Ana", sample, "sintetico2");
  store = await reopen(space, store);
  await store.renamePerson("Ana", "Alicia");
  const people = arr(await store.people());
  assert.equal(people[0]!.name, "Alicia");
  assert.equal(people[0]!.color, "#Ab12Cd");
  assert.equal(arr(people[0]!.voices).length, 2);
  assert.ok(!JSON.stringify(people).includes("embedding"));
  for (const invalid of ["red", "#abc", "#12345678", "#GG1234", "123456", "#12 456"]) await assert.rejects(store.setPersonColor("Alicia", invalid));
  await assert.rejects(store.setPersonColor("Desconocida", "#123456"));
  assert.deepEqual(await store.people(), people);
  await store.removePerson("Alicia");
  await store.addPersonVoice("Alicia", sample, "sintetico3");
  assert.equal(arr(await store.people())[0]!.color, undefined);
});

test("el color de una persona fusionada prioriza el destino y hereda si no tiene", async () => {
  for (const targetColor of [undefined, "#112233"]) {
    const local = await workspace();
    try {
      let store = await local.open();
      const sample = voice("S", [1, 0]);
      await store.addPersonVoice("Origen", sample, "sintetico");
      await store.addPersonVoice("Destino", sample, "sintetico");
      await store.setPersonColor("Origen", "#AABBCC");
      if (targetColor) await store.setPersonColor("Destino", targetColor);
      await store.renamePerson("Origen", "Destino");
      store = await reopen(local, store);
      const people = arr(await store.people());
      assert.equal(people.length, 1);
      assert.equal(people[0]!.name, "Destino");
      assert.equal(people[0]!.color, targetColor ?? "#AABBCC");
      assert.equal(arr(people[0]!.voices).length, 2);
    } finally {
      await local.dispose();
    }
  }
});

test("dividir un hablante conserva solo huellas con intervalos inequívocos", async () => {
  const { store, key, draft: initial } = await noteDraftFixture();
  await store.mutate("note_draft_discard", { recordingId: key, draftId: initial.id, expectedRevision: 0 });
  const transcript = await store.recognizeTranscription(key, { text: "uno dos tres", segments: [{ start: 0, end: 2, text: "uno dos", speaker: "A" }, { start: 2, end: 3, text: "tres", speaker: "B" }], voices: [voice("A", [1, 0]), voice("B", [0, 1])] });
  const source = obj(await store.mutate("version_save", { recordingId: key, transcript }));
  const cases: [unknown[], string[]][] = [
    [[{ start: 0, end: 1, text: "uno", speaker: "A" }, { start: 1, end: 2, text: "dos", speaker: "Persona" }, { start: 2, end: 3, text: "tres", speaker: "B" }], ["B"]],
    [[{ start: 0, end: 2, text: "uno", speaker: "A", timingShared: true }, { start: 0, end: 2, text: "dos", speaker: "Persona", timingShared: true }, { start: 2, end: 3, text: "tres", speaker: "B" }], ["B"]],
    [[{ start: 0, end: 1, text: "uno", speaker: "A" }, { start: 1, end: 2, text: "dos", speaker: "B" }, { start: 2, end: 3, text: "tres", speaker: "B" }], []],
    [[{ start: 0, end: 2, text: "uno dos", speaker: "A" }, { start: 2, end: 3, text: "tres", speaker: "B" }, { start: 2, end: 3, text: "duplicado", speaker: "Otra" }], ["A"]],
    [[{ start: 0, end: 2, text: "uno dos", speaker: "Renombrada" }, { start: 2, end: 3, text: "tres", speaker: "B" }], ["Renombrada", "B"]],
  ];
  for (const [segments, expected] of cases) {
    await store.mutate("version_select", { recordingId: key, versionId: source.id });
    const draft = obj(await store.mutate("note_draft_begin", { recordingId: key }));
    const content = obj(draft.content);
    obj(content.transcript).segments = segments as never;
    await store.mutate("note_draft_save", { recordingId: key, draftId: draft.id, expectedRevision: 0, content });
    const result = obj(await store.mutate("note_draft_commit", { recordingId: key, draftId: draft.id, expectedRevision: 1 }));
    const voices = await store.versionVoices(str(obj(result.version).id));
    assert.deepEqual(voices.map((item) => item.speaker), expected);
    assert.equal((await store.versionVoices(str(source.id))).length, 2);
    assert.deepEqual(await store.knownVoices(), []);
    assert.ok(!JSON.stringify(result).includes("embedding"));
  }
});
