import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Library } from "../../../src/runtime/library/library";
import { Store } from "../../../src/runtime/library/store";
import { arr, obj, str } from "./fixture";

let dir = "";
let opened: Library[] = [];
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "escriba-library-"));
});
afterEach(async () => {
  for (const library of opened.splice(0)) await library.close().catch(() => undefined);
  await rm(dir, { recursive: true, force: true });
});
async function open(root = join(dir, "library")) {
  const library = await Library.open(root);
  opened.push(library);
  return library;
}
async function reopen(library: Library, root = join(dir, "library")) {
  await library.close();
  opened.splice(opened.indexOf(library), 1);
  return open(root);
}
async function notes(library: Library, count: number): Promise<string[]> {
  const ids: string[] = [];
  for (let index = 0; index < count; index++) {
    const audio = join(dir, `sintetica-${index}.wav`);
    writeFileSync(audio, `audio sintético ${index}`);
    ids.push(str(obj(await library.withStore((store) => store.import(audio))).id));
  }
  return ids;
}
const retitle = (library: Library, id: string, title: string) => library.mutate("recording_update", { id, title });
const title = (library: Library, id: string) => library.index().recordings.find((record) => record.id === id)!.title;
const shape = (library: Library) => library.index().recordings.map((record) => ({ id: record.id, title: record.title, versions: (record.versions ?? []).map((version) => version.id) }));

test("las escrituras no se solapan", async () => {
  const library = await open();
  const ids = await notes(library, 6);
  const versions: Promise<string>[] = [];
  const titles: Promise<unknown>[] = [];
  for (let index = 0; index < 20; index++) {
    versions.push(library.mutate("version_save", { recordingId: ids[0], transcript: { text: `versión ${index}`, segments: [] } }).then((version) => str(obj(version).id)));
    titles.push(retitle(library, ids[1 + (index % 5)]!, `Título ${index}`));
  }
  const saved = new Set(await Promise.all(versions));
  await Promise.all(titles);
  assert.equal(saved.size, 20);
  const stored = new Set(arr((await library.recording(ids[0]!)).versions).map((version) => str(version.id)));
  assert.deepEqual(stored, saved);
  const published = shape(library);
  const reopened = await reopen(library);
  assert.deepEqual(shape(reopened), published);
});

test("lees lo que escribes y en orden", async () => {
  const library = await open();
  const ids = await notes(library, 4);
  let stop = false;
  const noise = ids.slice(1).map(async (id) => {
    let round = 0;
    while (!stop) {
      await retitle(library, id, `Ruido ${round}`);
      round += 1;
    }
  });
  for (let index = 0; index < 50; index++) {
    const expected = `Orden ${index}`;
    await retitle(library, ids[0]!, expected);
    assert.equal(title(library, ids[0]!), expected);
    assert.equal((await library.recording(ids[0]!)).title, expected);
  }
  stop = true;
  await Promise.all(noise);
});

test("un error no inutiliza la biblioteca", async () => {
  const library = await open();
  const ids = await notes(library, 1);
  await assert.rejects(retitle(library, "no-existe", "Sin nota"));
  await retitle(library, ids[0]!, "Tras el error");
  await assert.rejects(library.withStore(async () => { throw Error("Pánico provocado por la prueba"); }));
  await retitle(library, ids[0]!, "Tras el pánico");
  assert.equal(title(library, ids[0]!), "Tras el pánico");
});

test("cerrar confirma lo encolado", async () => {
  const root = join(dir, "library");
  const library = await open(root);
  for (let index = 0; index < 20; index++) library.log({ level: "error", message: `Orden encolada ${index}` });
  await library.close();
  opened.splice(opened.indexOf(library), 1);
  assert.throws(() => library.log({ level: "error", message: "Orden encolada tras cerrar" }));
  await assert.rejects(retitle(library, "cualquiera", "Tras cerrar"));
  const store = await Store.open(root);
  try {
    const lines = arr(await store.logList({ limit: 100 }));
    assert.equal(lines.filter((line) => str(line.message).startsWith("Orden encolada")).length, 20);
  } finally {
    await store.close();
  }
});

test("no se borran versiones mientras la nota tiene un trabajo pendiente", async () => {
  const library = await open();
  const [key] = await notes(library, 1);
  const first = str(obj(await library.mutate("version_save", { recordingId: key, transcript: { text: "uno", segments: [] } })).id);
  await library.mutate("version_save", { recordingId: key, transcript: { text: "dos", segments: [] } });
  await library.enqueueJob("processRecording", { recordingId: key, options: { force: true } }, false);
  await assert.rejects(library.removeVersions("version_delete", { recordingId: key, versionId: first }), /trabajo de esta nota/);
  await library.cancelJobs(key);
  await library.removeVersions("version_delete", { recordingId: key, versionId: first });
  assert.equal(arr(obj(await library.recording(key)).versions).length, 1);
});
