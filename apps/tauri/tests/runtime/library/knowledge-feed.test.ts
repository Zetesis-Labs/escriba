import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import type { CoreChange } from "../../../src/runtime/library/persistence";
import { arr, obj, str, workspace, reopen, type Workspace } from "./fixture";

let space: Workspace;
beforeEach(async () => {
  space = await workspace();
});
afterEach(async () => {
  await space.dispose();
});
const voice = (model: string, embedding: number[]) => ({ speaker: "Speaker 1", model, embedding });

test("el diario de conocimiento conserva cambios pendientes y no expone campos privados", async () => {
  const audio = space.path("sintetico.wav");
  writeFileSync(audio, "audio sintetico");
  let store = await space.open();
  assert.equal(await store.knowledgeChange(), undefined);
  const id = str(obj(await store.import(audio)).id);
  const initial = (await store.knowledgeChange())!;
  assert.equal(initial.kind, "recording");
  assert.equal(initial.id, id);
  await store.mutate("version_save", { recordingId: id, transcript: { text: "sintético", segments: [{ start: 0, end: 1, text: "sintético", words: [{ start: 0, end: 1, text: "sintético", secret: "prohibido" }], private: "prohibido" }], private: "prohibido" }, inputs: { secret: "prohibido" } });
  await store.knowledgeAck(initial.key, initial.revision);
  const changed = (await store.knowledgeChange())!;
  assert.notEqual(initial.revision, changed.revision);
  const value = obj(changed.value);
  const firstVersion = obj(arr(value.versions)[0]);
  const firstSegment = obj(arr(obj(firstVersion.transcript).segments)[0]);
  assert.equal(obj(arr(firstSegment.words)[0]).text, "sintético");
  assert.equal(value.audioPath, undefined);
  assert.ok(!JSON.stringify(value).includes("prohibido"));
  store = await reopen(space, store);
  const pending = (await store.knowledgeChange())!;
  assert.equal(changed.revision, pending.revision);
  await store.knowledgeAck(pending.key, pending.revision);
  assert.equal(await store.knowledgeChange(), undefined);
  await store.mutate("recording_discard", { id });
  const removed = (await store.knowledgeChange())!;
  assert.equal(removed.id, id);
  assert.equal(removed.value, null);
});

test("el diario de personas conserva la identidad al editar y omite biometría", async () => {
  const store = await space.open();
  await store.addPersonVoice("Ana", voice("modelo privado", [0.25, 0.75]), "ruta privada");
  const created = (await store.knowledgeChange())!;
  assert.equal(created.kind, "person");
  const value = obj(created.value);
  assert.equal(value.id, created.id);
  assert.equal(value.name, "Ana");
  assert.equal(Object.keys(value).length, 3);
  assert.equal(typeof value.createdAt, "string");
  await store.knowledgeAck(created.key, created.revision);
  await store.renamePerson("Ana", "Ana María");
  await store.setPersonColor("Ana María", "#123456");
  const updated = (await store.knowledgeChange())!;
  assert.equal(created.id, updated.id);
  assert.equal(obj(updated.value).name, "Ana María");
  assert.equal(obj(updated.value).color, "#123456");
  await store.knowledgeAck(updated.key, updated.revision);
  await store.removePerson("Ana María");
  const deleted = (await store.knowledgeChange())!;
  assert.equal(created.id, deleted.id);
  assert.equal(deleted.value, null);
});

test("el diario incorpora una biblioteca anterior una vez y detecta el borrado", async () => {
  const audio = space.path("sintetico.wav");
  writeFileSync(audio, "audio sintetico");
  let store = await space.open();
  const id = str(obj(await store.import(audio)).id);
  await store.database.queryTest("REMOVE EVENT knowledge_changed ON recording; REMOVE EVENT knowledge_changed ON version; REMOVE EVENT knowledge_changed ON person; REMOVE TABLE knowledge_dirty; REMOVE TABLE knowledge_meta");
  store = await reopen(space, store);
  const pending = (await store.knowledgeChange())!;
  assert.equal(pending.id, id);
  assert.equal(obj(pending.value).id, id);
  await store.knowledgeAck(pending.key, pending.revision);
  store = await reopen(space, store);
  assert.equal(await store.knowledgeChange(), undefined);
  await store.mutate("recording_delete", { id });
  const deleted = (await store.knowledgeChange())!;
  assert.equal(deleted.id, id);
  assert.equal(deleted.value, null);
});

test("el diario reconstruye una proyección nueva sin perder borrados pendientes", async () => {
  const audio = space.path("sintetico.wav");
  writeFileSync(audio, "audio sintetico");
  let store = await space.open();
  const recording = obj(await store.import(audio));
  await store.addPersonVoice("Ana", voice("sintetico", [0.5]), "sintetico");
  await store.knowledgePrepare("primera");
  const drain = async () => {
    const changes: CoreChange[] = [];
    for (;;) {
      const change = await store.knowledgeChange();
      if (!change) return changes;
      await store.knowledgeAck(change.key, change.revision);
      changes.push(change);
    }
  };
  const initial = await drain();
  assert.equal(initial.length, 2);
  await store.knowledgePrepare("primera");
  assert.equal(await store.knowledgeChange(), undefined);
  await store.knowledgePrepare("segunda");
  for (const old of initial) await store.knowledgeAck(old.key, old.revision);
  const rebuilt = await drain();
  assert.equal(rebuilt.length, 2);
  assert.ok(rebuilt.every((change) => change.value !== null));
  assert.equal(rebuilt.find((change) => change.kind === "recording")!.id, recording.id);
  store = await reopen(space, store);
  await store.knowledgePrepare("segunda");
  assert.equal(await store.knowledgeChange(), undefined);
  await store.removePerson("Ana");
  await store.knowledgePrepare("tercera");
  let deletion = false;
  let recordingRetained = false;
  for (;;) {
    const change = await store.knowledgeChange();
    if (!change) break;
    deletion ||= change.kind === "person" && change.value === null;
    recordingRetained ||= change.kind === "recording" && change.value !== null;
    await store.knowledgeAck(change.key, change.revision);
  }
  assert.ok(deletion && recordingRetained);
});
