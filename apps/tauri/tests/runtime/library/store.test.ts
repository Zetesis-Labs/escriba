import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { existsSync, readFileSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync, mkdirSync, chmodSync, readdirSync } from "node:fs";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { discardedRecord, redactedSettings, Store, SETTABLE, library as libraryView, markCredentials } from "../../../src/runtime/library/store";
import { importCreatedAt, stageAudio } from "../../../src/runtime/library/audio";
import { LOG_RETAINED } from "../../../src/runtime/library/persistence";
import { lightPublication, previewVersion, typedLibrary } from "../../../src/runtime/library/projection";
import { readLibraryData } from "../../../src/runtime/library/model";
import { fileCredentials } from "../../../src/runtime/credentials";
import { authorizedAccess } from "../../../src/runtime/http";
import { arr, obj, str, workspace, reopen, type Workspace } from "./fixture";

let space: Workspace;
beforeEach(async () => {
  space = await workspace();
});
afterEach(async () => {
  await space.dispose();
});
const write = (path: string, content: string | Buffer) => writeFileSync(path, content);
const secrets = (root: string) => fileCredentials(root);
const voice = (speaker: string, embedding: number[], model = "m") => ({ speaker, model, embedding });
const seconds = (value: number) => new Date(value * 1000);

test("abrir la lista no retiene transcripciones y el detalle conserva el original", async () => {
  const audio = space.path("sintetico.wav");
  write(audio, "audio de prueba");
  let store = await space.open();
  const recording = obj(await store.import(audio));
  const key = str(recording.id);
  const transcript = { text: "contenido ".repeat(1000), segments: [{ start: 0, end: 1, text: "segmento completo", words: [{ start: 0, end: 1, text: "palabra completa" }] }], extension: { retain: true } };
  const version = await store.mutate("version_save", { recordingId: key, transcript });
  store = await reopen(space, store);
  const cached = store.data.recordings[0]!.versions![0]!.transcript!;
  assert.deepEqual(cached.segments, [], "La lista conserva segmentos completos en RAM");
  assert.ok(Array.from(cached.text).length <= 400);
  assert.deepEqual(arr((await store.recording(key)).versions)[0], version);
  await store.mutate("settings_save", { settings: { notifyEveryNote: false } });
  await store.mutate("recording_update", { id: key, title: "Título nuevo" });
  assert.deepEqual(arr((await store.recording(key)).versions)[0]!.transcript, transcript);
  assert.deepEqual(store.data.recordings[0]!.versions![0]!.transcript!.segments, []);
});

test("fecha de incorporación usa la del fichero solo para captura recuperada", () => {
  assert.equal(importCreatedAt(seconds(1_700_000_000), seconds(1_750_000_000)), "2023-11-14T22:13:20+00:00");
  assert.equal(importCreatedAt(undefined, seconds(1_750_000_000)), "2025-06-15T15:06:40+00:00");
});

test("captura recuperada conserva la fecha del fichero tras reabrir la biblioteca", async () => {
  const capture = space.path("captura.m4a");
  write(capture, "audio sintetico");
  utimesSync(capture, seconds(1_700_000_000), seconds(1_700_000_000));
  let store = await space.open();
  const record = obj(await store.importRecoveredCapture(capture));
  assert.equal(record.createdAt, "2023-11-14T22:13:20+00:00");
  store = await reopen(space, store);
  assert.equal((await store.recording(str(record.id))).createdAt, "2023-11-14T22:13:20+00:00");
});

test("las personas guardan varias huellas privadas y solo exponen metadatos", async () => {
  let store = await space.open();
  await store.addPersonVoice("Rubén", voice("Speaker 1", [0.123456, -0.654321]), "a");
  await store.addPersonVoice("Rubén", voice("Speaker 2", [0.5, 0.5]), "b");
  const people = arr(await store.people());
  assert.equal(people.length, 1);
  assert.equal(people[0]!.name, "Rubén");
  assert.equal(arr(people[0]!.voices).length, 2);
  assert.equal(arr(people[0]!.voices)[0]!.source, "a");
  assert.ok(!JSON.stringify(people).includes("embedding"));
  assert.equal((await store.knownVoices()).length, 2);
  assert.ok(!JSON.stringify(await store.snapshot()).includes("0.123456"));
  store = await reopen(space, store);
  assert.equal((await store.knownVoices()).length, 2);
});

test("renombrar, juntar y quitar huellas conserva solo personas con voz", async () => {
  const store = await space.open();
  for (const [name, source, embedding] of [["Ruben", "a", [1, 0]], ["Ruben", "b", [0.9, 0.1]], ["Rubén G.", "c", [0, 1]], ["Ana", "d", [1, 1]]] as [string, string, number[]][])
    await store.addPersonVoice(name, voice("S", embedding), source);
  const redundant = str(arr(arr(await store.people()).find((person) => person.name === "Ruben")!.voices)[1]!.id);
  await store.removePersonVoice(redundant);
  await store.renamePerson("Ruben", "Rubén");
  await store.renamePerson("Rubén G.", "Rubén");
  await store.removePerson("Ana");
  const people = arr(await store.people());
  assert.equal(people.length, 1);
  assert.equal(people[0]!.name, "Rubén");
  assert.deepEqual(arr(people[0]!.voices).map((item) => item.source), ["a", "c"]);
  await store.removePersonVoice(str(arr(people[0]!.voices)[0]!.id));
  await store.removePersonVoice(str(arr(people[0]!.voices)[1]!.id));
  assert.deepEqual(await store.people(), []);
});

test("transcribir reconoce sin exponer huellas y la versión las conserva", async () => {
  const audio = space.path("sample.wav");
  write(audio, "synthetic audio");
  let store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  await store.addPersonVoice("Rubén", voice("S", [1, 0]), "muestra de voz");
  const transcript = obj(await store.recognizeTranscription(key, { text: "hola", segments: [{ speaker: "Speaker 1", start: 0, end: 1, text: "hola", words: [] }], voices: [{ speaker: "Speaker 1", model: "m", embedding: [1, 0.01] }] }));
  assert.equal(arr(transcript.segments)[0]!.speaker, "Rubén");
  const personId = str(arr(await store.people())[0]!.id);
  assert.equal(arr(transcript.segments)[0]!.personId, personId);
  assert.equal(arr(transcript.recognitions)[0]!.speaker, "Speaker 1");
  assert.ok(!JSON.stringify(transcript).includes("embedding"));
  const version = obj(await store.mutate("version_save", { recordingId: key, backend: "local-stt", transcript }));
  assert.equal(version.hasVoices, true);
  assert.equal((await store.versionVoices(str(version.id)))[0]!.speaker, "Rubén");
  assert.ok(!JSON.stringify(await store.snapshot()).includes("embedding"));
  assert.ok(!JSON.stringify(store.library()).includes("embedding"));
  assert.ok(!JSON.stringify(await store.recording(key)).includes("embedding"));
  assert.ok(!JSON.stringify(await store.runtimeContext(key)).includes("embedding"));
  store = await reopen(space, store);
  assert.equal((await store.versionVoices(str(version.id))).length, 1);
});

test("copiar versión reetiqueta huellas y rechaza origen de otra nota", async () => {
  const audio = space.path("sample.wav");
  const other = space.path("other.wav");
  write(audio, "synthetic audio");
  write(other, "other synthetic audio");
  const store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  const otherKey = str(obj(await store.import(other)).id);
  await store.addPersonVoice("Rubén", voice("S", [1, 0]), "muestra");
  const recognized = await store.recognizeTranscription(key, { text: "hola", segments: [{ speaker: "Speaker 1", start: 0, end: 1, text: "hola", words: [] }], voices: [{ speaker: "Speaker 1", model: "m", embedding: [1, 0.01] }] });
  const sourceId = str(obj(await store.mutate("version_save", { recordingId: key, transcript: recognized })).id);
  await assert.rejects(store.mutate("version_save", { recordingId: otherKey, sourceVersionId: sourceId, transcript: { text: "otra", segments: [] } }));
  const corrected = { text: "hola", segments: [{ speaker: "Speaker 1", start: 0, end: 1, text: "hola", words: [] }], recognitions: [] };
  const copy = obj(await store.mutate("version_save", { recordingId: key, sourceVersionId: sourceId, backend: "correccion", transcript: corrected }));
  assert.equal(copy.hasVoices, true);
  assert.equal((await store.versionVoices(str(copy.id)))[0]!.speaker, "Speaker 1");
  assert.equal((await store.versionVoices(sourceId))[0]!.speaker, "Rubén");
});

test("corregir enseña huellas atómicamente y fusión sin persona solo reetiqueta", async () => {
  const audio = space.path("sample.wav");
  write(audio, "synthetic audio");
  const store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  const transcript = await store.recognizeTranscription(key, { text: "hola", segments: [{ speaker: "Speaker 1", start: 0, end: 1, text: "hola", words: [] }], voices: [{ speaker: "Speaker 1", model: "m", embedding: [1, 0] }] });
  const source = obj(await store.mutate("version_save", { recordingId: key, transcript }));
  const corrected = { text: "hola", segments: [{ speaker: "Ana", start: 0, end: 1, text: "hola", words: [] }], recognitions: [] };
  const taught = obj(await store.mutate("version_save", { recordingId: key, sourceVersionId: source.id, backend: "correccion", transcript: corrected, teaching: { speaker: "Speaker 1", person: "Ana" } }));
  assert.equal(taught.learnedVoice, true);
  assert.equal(arr(await store.people())[0]!.name, "Ana");
  assert.equal(arr(arr(await store.people())[0]!.voices)[0]!.source, key);
  assert.equal((await store.versionVoices(str(taught.id)))[0]!.speaker, "Ana");
  const merged = obj(await store.mutate("version_save", { recordingId: key, sourceVersionId: taught.id, backend: "correccion", transcript: { text: "hola", segments: [{ speaker: "Nadie", start: 0, end: 1, text: "hola", words: [] }], recognitions: [] }, teaching: { speaker: "Ana", person: "Nadie", existingOnly: true } }));
  assert.equal(merged.learnedVoice, false);
  assert.equal((await store.versionVoices(str(merged.id)))[0]!.speaker, "Nadie");
  assert.equal(arr(await store.people()).length, 1);
});

test("avisar de cada nota se guarda aunque la biblioteca no lo tuviera", async () => {
  const store = await space.open();
  await store.mutate("settings_save", { settings: { notifyEveryNote: false, legacyWatchAdopted: true } });
  const settings = obj(obj(await store.dataJson()).settings);
  assert.equal(settings.notifyEveryNote, false);
  assert.equal(settings.legacyWatchAdopted, undefined);
});

test("una instalación nueva vigila Notas de Voz una sola vez", async () => {
  const memos = space.path("Recordings");
  const store = await space.open();
  assert.ok(await store.seedVoiceMemos(memos));
  const folders = arr(obj(obj(await store.dataJson()).settings).watchedFolders);
  assert.equal(folders.length, 1);
  assert.equal(folders[0]!.style, "voiceMemos");
  assert.equal(folders[0]!.path, memos);
  await store.mutate("settings_save", { settings: { watchedFolders: [] } });
  assert.ok(!(await store.seedVoiceMemos(memos)));
  assert.deepEqual(obj(obj(await store.dataJson()).settings).watchedFolders, []);
});

test("las carpetas que vienen de Swift no reciben Notas de Voz de regalo", async () => {
  const store = await space.open();
  const next = obj(await store.dataJson());
  obj(next.settings).legacyWatchAdopted = true;
  await store.replace(next);
  assert.ok(!(await store.seedVoiceMemos(space.path("Recordings"))));
  const settings = obj(obj(await store.dataJson()).settings);
  assert.deepEqual(settings.watchedFolders, []);
  assert.equal(settings.voiceMemosSeeded, true);
});

test("carpeta autorizada persiste y el bookmark no sale en respuestas", async () => {
  const folder = space.path("VoiceMemos");
  mkdirSync(folder, { recursive: true });
  const bytes = [...Buffer.from("synthetic-private-bookmark")];
  let store = await space.open();
  const created = obj(await store.authorizeWatchedFolder(undefined, folder, "Notas", "voiceMemos", bytes));
  const id = str(created.id);
  assert.equal(created.authorizationSaved, true);
  assert.equal(created.accessBookmark, undefined);
  assert.deepEqual(store.watchedFolderBookmarks()[0]![2], bytes);
  const snapshot = await store.snapshot();
  const folders = arr(obj(snapshot.settings).watchedFolders);
  assert.equal(folders[0]!.authorizationSaved, true);
  assert.equal(folders[0]!.accessBookmark, undefined);
  const reply = obj(await store.mutate("settings_save", { settings: { watchedFolders: folders } }));
  assert.equal(arr(reply.watchedFolders)[0]!.accessBookmark, undefined);
  assert.deepEqual(store.watchedFolderBookmarks()[0]![2], bytes);
  store = await reopen(space, store);
  assert.equal(store.watchedFolderBookmarks()[0]![0], id);
  assert.deepEqual(store.watchedFolderBookmarks()[0]![2], bytes);
  assert.ok(!JSON.stringify(await store.snapshot()).includes("synthetic-private-bookmark"));
});

test.runIf(process.platform === "linux")("en Linux una carpeta se guarda sin bookmark y se vigila por su ruta", async () => {
  const folder = space.path("Grabaciones");
  mkdirSync(folder, { recursive: true });
  const store = await space.open();
  const created = obj(await store.authorizeWatchedFolder(undefined, folder, undefined, "any", []));
  assert.equal(created.authorizationSaved, false);
  assert.equal(created.accessBookmark, undefined);
  assert.deepEqual(store.watchedFolderBookmarks(), []);
  const folders = arr(obj((await store.snapshot()).settings).watchedFolders);
  assert.equal(folders[0]!.path, realpathSync(folder));
  assert.equal(folders[0]!.name, "Grabaciones");
  const again = obj(await store.authorizeWatchedFolder(undefined, folder, undefined, "any", []));
  assert.equal(again.id, created.id);
});

test.runIf(process.platform === "darwin")("en macOS una carpeta sin autorización no se guarda", async () => {
  const folder = space.path("Grabaciones");
  mkdirSync(folder, { recursive: true });
  const store = await space.open();
  await assert.rejects(store.authorizeWatchedFolder(undefined, folder, undefined, "any", []), /La autorización de carpeta está vacía/);
});

test("reautorizar misma ruta conserva metadatos y cambiar o quitar revoca", async () => {
  const first = space.path("first");
  const second = space.path("second");
  mkdirSync(first);
  mkdirSync(second);
  const store = await space.open();
  const folder = obj(await store.authorizeWatchedFolder(undefined, first, "Original", "voiceMemos", [...Buffer.from("first-bookmark")]));
  const id = str(folder.id);
  await store.mutate("settings_save", { settings: { watchedFolders: [{ id, path: first, name: "Chosen", style: "any", enabled: false, authorizationSaved: false, accessBookmark: [1, 2, 3] }] } });
  assert.equal(store.watchedFolderBookmarks().length, 0);
  const duplicate = obj(await store.authorizeWatchedFolder(undefined, first, "Ignored", "justPressRecord", [...Buffer.from("second-bookmark")]));
  assert.equal(duplicate.id, id);
  assert.equal(duplicate.name, "Chosen");
  assert.equal(duplicate.style, "any");
  assert.equal(duplicate.enabled, false);
  await assert.rejects(store.authorizeWatchedFolder(id, second, undefined, "any", [...Buffer.from("wrong-path")]));
  assert.deepEqual(arr(obj(obj(await store.dataJson()).settings).watchedFolders)[0]!.accessBookmark, [...Buffer.from("second-bookmark")]);
  await store.mutate("settings_save", { settings: { watchedFolders: [{ id, path: second, name: "Moved", style: "any", enabled: true, accessBookmark: [9, 9], authorizationSaved: true }] } });
  assert.deepEqual(store.watchedFolderBookmarks(), []);
  assert.equal(arr(obj(obj(await store.dataJson()).settings).watchedFolders)[0]!.accessBookmark, undefined);
  await store.mutate("settings_save", { settings: { watchedFolders: [] } });
  assert.deepEqual(obj(obj(await store.dataJson()).settings).watchedFolders, []);
});

test("renovar bookmark respeta actualizaciones concurrentes y traslados", async () => {
  const old = space.path("old");
  const moved = space.path("moved");
  mkdirSync(old);
  mkdirSync(moved);
  const store = await space.open();
  const id = str(obj(await store.authorizeWatchedFolder(undefined, old, undefined, "any", [...Buffer.from("original")])).id);
  assert.ok(!(await store.refreshWatchedFolderBookmark(id, [...Buffer.from("stale")], moved, [...Buffer.from("replacement")])));
  assert.equal(arr(obj(obj(await store.dataJson()).settings).watchedFolders)[0]!.path, realpathSync(old));
  assert.ok(await store.refreshWatchedFolderBookmark(id, [...Buffer.from("original")], moved, [...Buffer.from("replacement")]));
  assert.equal(arr(obj(obj(await store.dataJson()).settings).watchedFolders)[0]!.path, realpathSync(moved));
  assert.deepEqual(store.watchedFolderBookmarks()[0]![2], [...Buffer.from("replacement")]);
  assert.ok(!(await store.refreshWatchedFolderBookmark(id, [...Buffer.from("original")], old)));
  await store.mutate("settings_save", { settings: { watchedFolders: [] } });
  assert.ok(!(await store.refreshWatchedFolderBookmark(id, [...Buffer.from("replacement")], old)));
});

test("reautorizar carpeta trasladada conserva identidad y no usurpa otra", async () => {
  const first = space.path("first");
  const moved = space.path("moved");
  const second = space.path("second");
  mkdirSync(first);
  mkdirSync(second);
  const store = await space.open();
  const original = obj(await store.authorizeWatchedFolder(undefined, first, "Original", "voiceMemos", [...Buffer.from("old")]));
  const other = obj(await store.authorizeWatchedFolder(undefined, second, "Otra", "any", [...Buffer.from("other")]));
  const id = str(original.id);
  await store.mutate("settings_save", { settings: { watchedFolders: [{ id, path: first, name: "Elegida", style: "voiceMemos", enabled: false }, other] } });
  renameSync(first, moved);
  await assert.rejects(store.authorizeWatchedFolder(id, second, undefined, "any", [...Buffer.from("wrong")]));
  const saved = obj(await store.authorizeWatchedFolder(id, moved, "Ignorado", "justPressRecord", [...Buffer.from("new")]));
  assert.equal(saved.id, original.id);
  assert.equal(saved.path, realpathSync(moved));
  assert.equal(saved.name, "Elegida");
  assert.equal(saved.style, "voiceMemos");
  assert.equal(saved.enabled, false);
  assert.equal(saved.authorizationSaved, true);
  assert.equal(saved.accessBookmark, undefined);
  const folders = arr(obj(store.settingsJson()).watchedFolders);
  assert.equal(folders.length, 2);
  assert.deepEqual(folders[0]!.accessBookmark, [...Buffer.from("new")]);
  assert.equal(folders[1]!.id, other.id);
  assert.deepEqual(folders[1]!.accessBookmark, [...Buffer.from("other")]);
});

test("biblioteca importada conserva transcripción y descarte al reabrir y vigilar", async () => {
  const source = space.path("note.wav");
  write(source, "synthetic imported audio");
  let store = await space.open();
  const id = str(obj(await store.import(source)).id);
  await store.mutate("version_save", { recordingId: id, backend: "whisperkit", transcript: { text: "Conservada", segments: [] } });
  const data = obj(await store.dataJson());
  arr(data.recordings)[0]!.sourceKey = "swift:123";
  arr(data.recordings)[0]!.legacyKey = "123";
  arr(data.recordings).push({ id: "discarded", status: "discarded", source: space.path("old.wav"), sourceKey: "swift:456", legacyKey: "456" });
  await store.replace(data);
  const versions = (await store.recording(id)).versions;
  store = await reopen(space, store);
  const renamed = space.path("renamed.wav");
  renameSync(source, renamed);
  const refreshed = obj(await store.importWithMetadata(renamed, undefined, "Renamed", new Date(), "voiceMemos:folder/123"));
  assert.equal(refreshed.id, id);
  assert.deepEqual((await store.recording(id)).versions, versions);
  assert.deepEqual(obj(arr(refreshed.versions)[0]!.transcript).segments, []);
  const discardedSource = space.path("discarded-renamed.wav");
  write(discardedSource, "discarded audio");
  const discarded = obj(await store.importWithMetadata(discardedSource, undefined, "Discarded", new Date(), "voiceMemos:folder/456"));
  assert.equal(discarded.status, "discarded");
  assert.equal(discarded.id, "discarded");
  assert.equal(arr(obj(await store.dataJson()).recordings).length, 2);
});

test("preserva versiones y selección al reiniciar", async () => {
  const audio = space.path("test.wav");
  write(audio, "synthetic audio");
  let store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  const first = obj(await store.mutate("version_save", { recordingId: key, backend: "test", transcript: { text: "hola", segments: [] } }));
  const second = obj(await store.mutate("version_save", { recordingId: key, backend: "test", transcript: { text: "corregido", segments: [] } }));
  await store.mutate("version_update", { recordingId: key, versionId: first.id, digest: { title: "Primera", summary: "Resumen", tags: [] } });
  assert.equal((await store.recording(key)).currentVersionId, second.id);
  store = await reopen(space, store);
  const saved = await store.recording(key);
  assert.equal(arr(saved.versions).length, 2);
  assert.equal(obj(arr(saved.versions)[0]!.digest).title, "Primera");
});

test("incorporar sin elegir receta no fija la predeterminada", async () => {
  const audio = space.path("prueba.wav");
  write(audio, "audio sintetico");
  let store = await space.open();
  const recording = obj(await store.import(audio));
  assert.equal(recording.recipeId, null);
  store = await reopen(space, store);
  assert.equal((await store.recording(str(recording.id))).recipeId, null);
});

test("una grabación vacía no fija receta y la elección explícita se conserva", async () => {
  const audio = space.path("prueba.wav");
  let store = await space.open();
  const empty = obj(await store.mutate("recording_abandoned", { path: audio }));
  assert.equal(empty.recipeId, null);
  write(audio, "audio sintetico elegido");
  const recording = obj(await store.import(audio, "elegida"));
  assert.equal(recording.recipeId, "elegida");
  store = await reopen(space, store);
  assert.equal((await store.recording(str(recording.id))).recipeId, "elegida");
});

test("deduplica audio y conserva el libro de descartes", async () => {
  const audio = space.path("test.wav");
  write(audio, "audio");
  const store = await space.open();
  const r = obj(await store.import(audio));
  await store.mutate("recording_discard", { id: r.id });
  const again = obj(await store.import(audio));
  assert.equal(again.status, "discarded");
  assert.equal(arr((await store.snapshot()).recordings).length, 1);
});

test("borrar de biblioteca deja solo identidad y borra contenido y copia", async () => {
  const source = space.path("captura.wav");
  write(source, "audio sintetico privado");
  let store = await space.open();
  const key = str(obj(await store.import(source)).id);
  const copy = store.audio(key);
  await store.mutate("version_save", { recordingId: key, transcript: { text: "transcripción privada", segments: [] }, digest: { title: "título privado", summary: "resumen privado" }, data: { detalle: "dato privado" } });
  const discarded = await store.mutate("recording_discard", { id: key });
  const tombstone = { id: key, source, sourceKey: null, legacyKey: null, status: "discarded" };
  assert.deepEqual(discarded, tombstone);
  assert.ok(!existsSync(copy));
  assert.ok(existsSync(source));
  store = await reopen(space, store);
  assert.deepEqual(await store.recording(key), tombstone);
});

test("descartar guarda borrado pendiente y reintenta tras caída", async () => {
  const source = space.path("original.wav");
  write(source, "audio sintetico");
  let store = await space.open(space.library, { audioCleanup: false });
  const record = obj(await store.import(source));
  const id = str(record.id);
  const copy = store.audio(id);
  await store.mutate("recording_discard", { id });
  assert.deepEqual(await store.recording(id), discardedRecord(record));
  assert.ok(existsSync(copy));
  assert.equal((await store.database.pendingAudioDeletions()).length, 1);
  assert.ok(!JSON.stringify(await store.snapshot()).includes(copy));
  store = await reopen(space, store);
  assert.ok(!existsSync(copy));
  assert.ok(existsSync(source));
  assert.deepEqual(await store.database.pendingAudioDeletions(), []);
  assert.deepEqual(await store.recording(id), discardedRecord(record));
});

test("arranque guarda el borrado de audio antes de limpiar lápida antigua", async () => {
  const source = space.path("original.wav");
  write(source, "audio sintetico");
  let store = await space.open();
  const record = obj(await store.import(source));
  const id = str(record.id);
  const copy = store.audio(id);
  const legacy = obj(await store.dataJson());
  arr(legacy.recordings)[0]!.status = "discarded";
  await store.replace(legacy);
  await space.close(store);
  const interrupted = await space.open(space.library, { audioCleanup: false });
  assert.deepEqual(await interrupted.recording(id), discardedRecord(record));
  assert.ok(existsSync(copy));
  assert.equal((await interrupted.database.pendingAudioDeletions()).length, 1);
  store = await reopen(space, interrupted);
  assert.ok(!existsSync(copy));
  assert.ok(existsSync(source));
  assert.deepEqual(await store.database.pendingAudioDeletions(), []);
});

test("borrado pendiente ausente se da por completado al abrir", async () => {
  const source = space.path("original.wav");
  write(source, "audio sintetico");
  let store = await space.open(space.library, { audioCleanup: false });
  const record = obj(await store.import(source));
  const copy = store.audio(str(record.id));
  await store.mutate("recording_discard", { id: record.id });
  rmSync(copy);
  store = await reopen(space, store);
  assert.deepEqual(await store.database.pendingAudioDeletions(), []);
  assert.ok(existsSync(source));
});

test("borrado pendiente no sigue enlace a original fuera de audio", async () => {
  const source = space.path("original.wav");
  write(source, "audio sintetico");
  let store = await space.open(space.library, { audioCleanup: false });
  const record = obj(await store.import(source));
  const copy = store.audio(str(record.id));
  await store.mutate("recording_discard", { id: record.id });
  rmSync(copy);
  symlinkSync(source, copy);
  await space.close(store);
  await assert.rejects(Store.open(space.library));
  await assert.rejects(Store.open(space.library));
  assert.equal(readFileSync(source, "utf8"), "audio sintetico");
  rmSync(copy);
  store = await space.open();
  assert.deepEqual(await store.database.pendingAudioDeletions(), []);
});

test("borrado pendiente no borra otro archivo que ocupa la misma ruta", async () => {
  const source = space.path("original.wav");
  write(source, "audio sintetico");
  let store = await space.open(space.library, { audioCleanup: false });
  const record = obj(await store.import(source));
  const copy = store.audio(str(record.id));
  await store.mutate("recording_discard", { id: record.id });
  rmSync(copy);
  write(copy, "otro audio sintetico");
  await space.close(store);
  await assert.rejects(Store.open(space.library));
  assert.equal(readFileSync(copy, "utf8"), "otro audio sintetico");
  rmSync(copy);
  store = await space.open();
  assert.deepEqual(await store.database.pendingAudioDeletions(), []);
  assert.ok(existsSync(source));
});

test("origen externo no comprobable no bloquea borrado de copia local", async () => {
  const source = space.path("original.wav");
  const other = space.path("other.wav");
  const notADirectory = space.path("archivo");
  write(source, "audio uno");
  write(other, "audio dos");
  write(notADirectory, "no es carpeta");
  const store = await space.open();
  const first = obj(await store.import(source));
  const second = obj(await store.import(other));
  const copy = store.audio(str(first.id));
  const changed = obj(await store.dataJson());
  arr(changed.recordings).find((record) => record.id === second.id)!.source = join(notADirectory, "child.wav");
  await store.replace(changed);
  await store.mutate("recording_discard", { id: first.id });
  assert.ok(!existsSync(copy));
  assert.ok(existsSync(source));
  assert.ok(existsSync(other));
});

test("descarte no borra original ajeno ni copia compartida activa", async () => {
  const source = space.path("original.wav");
  const other = space.path("other.wav");
  write(source, "audio uno");
  write(other, "audio dos");
  const store = await space.open();
  const first = obj(await store.import(source));
  const second = obj(await store.import(other));
  const copy = store.audio(str(first.id));
  let changed = obj(await store.dataJson());
  arr(changed.recordings).find((record) => record.id === second.id)!.audioPath = copy;
  await store.replace(changed);
  await store.mutate("recording_discard", { id: first.id });
  assert.ok(existsSync(copy));
  assert.deepEqual(await store.database.pendingAudioDeletions(), []);
  changed = obj(await store.dataJson());
  arr(changed.recordings).find((record) => record.id === second.id)!.audioPath = source;
  await store.replace(changed);
  await assert.rejects(store.mutate("recording_discard", { id: second.id }));
  assert.ok(existsSync(source));
  assert.equal((await store.recording(str(second.id))).status, "pending");
});

test("arranque normaliza descartados antiguos y retira su copia de audio", async () => {
  const source = space.path("captura.wav");
  write(source, "audio sintetico privado");
  let store = await space.open();
  const first = obj(await store.import(source));
  const key = str(first.id);
  const copy = store.audio(key);
  const legacy = obj(await store.dataJson());
  arr(legacy.recordings)[0]!.status = "discarded";
  await store.replace(legacy);
  store = await reopen(space, store);
  assert.deepEqual(await store.recording(key), discardedRecord(first));
  assert.ok(!existsSync(copy));
  assert.ok(existsSync(source));
});

test("borrar limpia memoria, traza, trabajo y huella de versión sin olvidar persona", async () => {
  const source = space.path("captura.wav");
  write(source, "audio sintetico");
  const store = await space.open();
  const key = str(obj(await store.import(source)).id);
  const transcript = await store.recognizeTranscription(key, { text: "texto privado", segments: [], voices: [{ speaker: "Hablante", model: "modelo-sintetico", embedding: [1, 0] }] });
  const version = obj(await store.mutate("version_save", { recordingId: key, transcript }));
  const versionId = str(version.id);
  assert.equal((await store.versionVoices(versionId)).length, 1);
  await store.memoryKeep(key, versionId, "huella-sintetica", { value: "recuerdo privado" });
  const memoryKey = JSON.stringify([key, versionId, "huella-sintetica"]);
  await store.traceSave({ id: "traza", recordingId: key, startedAt: "2026-10-10", detail: "privado" });
  await store.jobSave({ id: "trabajo", recordingId: key, state: "cancelled" });
  await store.addPersonVoice("Persona", voice("Hablante", [1, 0], "modelo-sintetico"), key);
  await store.mutate("recording_discard", { id: key });
  assert.deepEqual(await store.versionVoices(versionId), []);
  assert.equal(await store.database.recall(memoryKey), undefined);
  assert.deepEqual(await store.traceList(key), []);
  assert.deepEqual(await store.jobs(), []);
  assert.equal(arr(await store.people())[0]!.name, "Persona");
});

test("vigilancia no resucita una lápida aunque cambie el audio", async () => {
  const source = space.path("nota.m4a");
  write(source, "primera version sintetica");
  const store = await space.open();
  const first = obj(await store.importWithMetadata(source, undefined, "Nota", new Date(), "voiceMemos:folder/42"));
  const key = str(first.id);
  const tombstone = await store.mutate("recording_discard", { id: key });
  write(source, "segunda version sintetica");
  const scanned = await store.importWithMetadata(source, undefined, "Título posterior", new Date(), "voiceMemos:folder/42");
  assert.deepEqual(scanned, tombstone);
  assert.deepEqual(await store.recording(key), tombstone);
  assert.deepEqual(await store.jobs(), []);
});

test("vigilancia reconoce por origen la lápida de una importación manual", async () => {
  const source = space.path("nota.m4a");
  write(source, "audio sintetico");
  const store = await space.open();
  const first = obj(await store.import(source));
  const tombstone = await store.mutate("recording_discard", { id: first.id });
  const watched = await store.importWithMetadata(source, undefined, "Nota vigilada", new Date(), "voiceMemos:folder/42");
  assert.deepEqual(watched, tombstone);
  assert.equal(arr(obj(await store.dataJson()).recordings).length, 1);
});

test("respuestas tardías no escriben sobre una grabación descartada", async () => {
  const source = space.path("nota.wav");
  write(source, "audio sintetico");
  const store = await space.open();
  const key = str(obj(await store.import(source)).id);
  const tombstone = await store.mutate("recording_discard", { id: key });
  await assert.rejects(store.mutate("recording_update", { id: key, status: "done" }));
  await assert.rejects(store.mutate("version_save", { recordingId: key, transcript: { text: "tarde", segments: [] } }));
  await assert.rejects(store.mutate("publication_save", { recordingId: key, destinationId: "d", receipt: {} }));
  await assert.rejects(store.traceSave({ recordingId: key, detail: "tarde" }));
  await assert.rejects(store.jobSave({ id: "tarde", recordingId: key, state: "queued" }));
  await assert.rejects(store.recognizeTranscription(key, { text: "tarde", segments: [], voices: [] }));
  await assert.rejects(store.mutate("recording_restore", { id: key }));
  assert.deepEqual(await store.recording(key), tombstone);
  assert.deepEqual(await store.jobs(), []);
  assert.deepEqual(await store.traceList(key), []);
});

test("una nota de voz vigilada renombrada o revisada conserva identidad y versiones", async () => {
  const source = space.path("old.mov");
  write(source, "first audio");
  const store = await space.open();
  const started = seconds(1_700_000_000);
  const first = obj(await store.importWithMetadata(source, undefined, "Antiguo", started, "voiceMemos:folder/42"));
  const recordingId = str(first.id);
  const firstCopy = store.audio(recordingId);
  await store.mutate("version_save", { recordingId, transcript: { text: "primera", segments: [] } });
  const renamed = space.path("new.mov");
  renameSync(source, renamed);
  const same = obj(await store.importWithMetadata(renamed, undefined, "Nuevo", started, "voiceMemos:folder/42"));
  assert.equal(same.id, first.id);
  assert.equal(same.title, "Nuevo");
  assert.equal(same.source, renamed);
  assert.equal(arr(obj(await store.dataJson()).recordings).length, 1);
  write(renamed, "second audio");
  const revised = obj(await store.importWithMetadata(renamed, undefined, "Nuevo", started, "voiceMemos:folder/42"));
  assert.equal(revised.id, first.id);
  assert.equal(arr(revised.versions).length, 1);
  assert.equal(revised.status, "pending");
  assert.ok(!existsSync(firstCopy));
  assert.equal(readFileSync(store.audio(recordingId), "utf8"), "second audio");
});

test("un audio vigilado que cambia espera al trabajo activo antes de sustituir la copia", async () => {
  const source = space.path("voice.m4a");
  write(source, "first audio");
  const store = await space.open();
  const started = seconds(1_700_000_000);
  const first = obj(await store.importWithMetadata(source, undefined, "Original", started, "voiceMemos:folder/42"));
  const recordingId = str(first.id);
  const oldCopy = store.audio(recordingId);
  await store.mutate("version_save", { recordingId, transcript: { text: "primera", segments: [] } });
  await store.jobSave({ id: "job-1", recordingId, state: "queued" });
  const renamed = space.path("voice-renamed.m4a");
  renameSync(source, renamed);
  const sameAudio = obj(await store.importWithMetadata(renamed, undefined, "Renamed", started, "voiceMemos:folder/42"));
  assert.equal(sameAudio.id, first.id);
  assert.equal(sameAudio.status, first.status);
  assert.equal(sameAudio.title, "Renamed");
  assert.equal(store.audio(recordingId), oldCopy);
  write(renamed, "second audio");
  for (const state of ["queued", "running", "retry"]) {
    await store.jobSave({ id: "job-1", recordingId, state });
    await assert.rejects(store.importWithMetadata(renamed, undefined, "Actualizado", started, "voiceMemos:folder/42"), /trabajo activo/);
    assert.equal(store.audio(recordingId), oldCopy);
    assert.equal(readFileSync(oldCopy, "utf8"), "first audio");
    assert.equal((await store.recording(recordingId)).title, "Renamed");
    assert.equal(arr((await store.recording(recordingId)).versions).length, 1);
  }
  await store.jobSave({ id: "job-1", recordingId, state: "succeeded" });
  const revised = obj(await store.importWithMetadata(renamed, undefined, "Actualizado", started, "voiceMemos:folder/42"));
  assert.equal(revised.id, first.id);
  assert.equal(revised.title, "Actualizado");
  assert.equal(arr(revised.versions).length, 1);
  assert.ok(!existsSync(oldCopy));
  assert.equal(readFileSync(store.audio(recordingId), "utf8"), "second audio");
});

test("las credenciales no entran en el snapshot", async () => {
  const store = await space.open();
  await store.mutate("config_save", { collection: "accounts", item: { id: "notion", name: "Notion", provider: "notion", enabled: true, token: "must-not-persist" } });
  await secrets(space.library).save("notion", "fake-local-secret");
  const state = JSON.stringify(await store.snapshot());
  assert.ok(!state.includes("fake-local-secret"));
  assert.ok(!state.includes("must-not-persist"));
  assert.equal(store.credential("notion"), "fake-local-secret");
});

// Builds a large synthetic library: slower machines need more than the default 5 s.
test("el contexto de ejecución limita una biblioteca grande a la grabación pedida", { timeout: 30_000 }, async () => {
  const store = await space.open();
  const selectedPath = "/private/audio/selected.wav";
  const otherMarker = "foreign-recording-marker";
  const selected = { id: "selected", status: "done", title: "Selected", audioPath: selectedPath, source: "/private/source/selected.wav", sourceKey: "/private/source-key", legacyKey: "/private/legacy-key", versions: [{ id: "version-1", transcript: { text: "reusable transcript", segments: [] }, inputs: { backend: "local-stt" } }], publications: [{ destinationId: "destination-1", receipt: { locator: "receipt-1" } }] };
  const data = obj(await store.dataJson());
  data.recordings = [selected, { id: "other", status: "done", title: otherMarker, audioPath: "/private/audio/other.wav", versions: [{ id: "other-version", transcript: { text: "X".repeat(33 * 1024 * 1024), segments: [] } }], publications: [] }];
  obj(data.settings).watchedFolders = [{ id: "folder-1", path: "/private/watched", name: "Watched", accessBookmark: [1, 2, 3] }];
  data.logs = [{ id: "log-1", message: "private log marker" }];
  data.accounts = [{ id: "account-1", name: "Account", provider: "okf", enabled: true, folder: "/private/account-folder" }];
  await store.replace(data);
  await secrets(space.library).save("account-1", "synthetic-secret");
  assert.ok(JSON.stringify(await store.snapshot()).length > 32 * 1024 * 1024);
  const context = await store.runtimeContext("selected");
  const serialized = JSON.stringify(context);
  assert.ok(serialized.length < 1024 * 1024);
  assert.equal(arr(context.recordings).length, 1);
  const only = arr(context.recordings)[0]!;
  assert.equal(only.id, "selected");
  assert.equal(only.audioPath, "available");
  assert.equal(only.source, "urn:escriba:recording:selected");
  assert.equal(only.sourceKey, undefined);
  assert.equal(only.legacyKey, undefined);
  assert.deepEqual(only.versions, selected.versions);
  assert.deepEqual(only.publications, selected.publications);
  assert.equal(arr(context.accounts)[0]!.hasCredential, true);
  assert.equal(Object.keys(obj(context.settings)).length, 3);
  assert.equal(context.logs, undefined);
  assert.equal(context.dataPath, undefined);
  for (const forbidden of [otherMarker, "other-version", selectedPath, "/private/", "private log marker", "synthetic-secret", "accessBookmark"]) assert.ok(!serialized.includes(forbidden), forbidden);
  const folderFingerprint = str(arr(context.accounts)[0]!.folder);
  assert.ok(folderFingerprint.startsWith("urn:escriba:folder:"));
  assert.equal(arr((await store.runtimeContext()).accounts)[0]!.folder, folderFingerprint);
  const changed = obj(await store.dataJson());
  arr(changed.accounts)[0]!.folder = "/private/changed-folder";
  await store.replace(changed);
  assert.notEqual(arr((await store.runtimeContext()).accounts)[0]!.folder, folderFingerprint);
  const catalog = await store.runtimeContext();
  assert.deepEqual(catalog.recordings, []);
  assert.deepEqual(catalog.recipes, (await store.snapshot()).recipes);
  await assert.rejects(store.runtimeContext("missing"), /Grabación no encontrada/);
});

test("RocksDB conserva las versiones tras retirar el JSON", async () => {
  const audio = space.path("note.wav");
  write(audio, "synthetic audio");
  let store = await space.open();
  const record = obj(await store.import(audio));
  await store.mutate("version_save", { recordingId: record.id, backend: "test", transcript: { text: "texto", segments: [] } });
  await space.close(store);
  rmSync(join(space.library, "library.json"), { force: true });
  store = await space.open();
  assert.ok(statSync(join(space.library, "library.rocksdb")).isDirectory());
  assert.equal(obj(arr((await store.recording(str(record.id))).versions)[0]!.transcript).text, "texto");
});

test("las filas confirmadas sobreviven a matar el proceso", async () => {
  const root = space.library;
  mkdirSync(root, { recursive: true });
  const script = fileURLToPath(new URL("./crash-child.ts", import.meta.url));
  const child = spawn("bun", ["run", script, root], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const ready = join(root, "child-ready");
  const deadline = Date.now() + 20000;
  while (!existsSync(ready) && Date.now() < deadline) {
    if (child.exitCode !== null) throw Error(`El proceso hijo terminó antes de guardar: ${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.ok(existsSync(ready), `El proceso hijo no confirmó el commit: ${stderr}`);
  child.kill("SIGKILL");
  await new Promise((resolve) => child.on("exit", resolve));
  const store = await space.open();
  assert.equal(obj((await store.logList({}))[0])!.message, "committed before kill");
}, 40000);

test("las filas de SurrealDB exponen campos nativos y objetos", async () => {
  const source = space.path("note.wav");
  write(source, "synthetic audio");
  const store = await space.open();
  const recording = obj(await store.import(source));
  await store.mutate("version_save", { recordingId: recording.id, backend: "whisper", transcript: { text: "hola", segments: [] } });
  await store.jobSave({ id: "job-1", recordingId: recording.id, state: "queued" });
  const records = arr(await store.database.selectTest("SELECT title, status, payload.title AS nestedTitle FROM recording"));
  assert.equal(records[0]!.title, "note");
  assert.equal(records[0]!.status, "pending");
  assert.equal(records[0]!.nestedTitle, "note");
  const versions = arr(await store.database.selectTest("SELECT backend, payload.transcript.text AS transcriptText FROM version"));
  assert.equal(versions[0]!.backend, "whisper");
  assert.equal(versions[0]!.transcriptText, "hola");
  const jobs = arr(await store.database.selectTest("SELECT state, recordingId FROM job"));
  assert.equal(jobs[0]!.state, "queued");
  assert.equal(jobs[0]!.recordingId, recording.id);
});

test("las filas de texto del esquema anterior se actualizan transaccionalmente a objetos", async () => {
  const source = space.path("note.wav");
  write(source, "synthetic audio");
  let store = await space.open();
  const recordingId = str(obj(await store.import(source)).id);
  await store.jobSave({ id: "job-1", recordingId, state: "queued" });
  await store.database.downgradeV1Test();
  store = await reopen(space, store);
  assert.equal((await store.recording(recordingId)).title, "note");
  assert.equal(obj((await store.jobs())[0]).state, "queued");
  assert.equal(obj((await store.database.selectTest("SELECT status, payload.title AS nestedTitle FROM recording"))[0]).nestedTitle, "note");
  assert.equal(obj((await store.database.selectTest("SELECT payload FROM meta WHERE key = 'schema'"))[0]).payload, "2");
});

test("las carpetas privadas y el audio importado tienen permisos restringidos", async () => {
  mkdirSync(space.library);
  chmodSync(space.library, 0o755);
  const source = space.path("note.wav");
  write(source, "synthetic audio");
  const store = await space.open();
  assert.equal(statSync(space.library).mode & 0o777, 0o700);
  assert.equal(statSync(join(space.library, "audio")).mode & 0o777, 0o700);
  assert.equal(statSync(join(space.library, "library.rocksdb")).mode & 0o777, 0o700);
  const recording = obj(await store.import(source));
  assert.equal(statSync(store.audio(str(recording.id))).mode & 0o777, 0o600);
});

test("los trabajos sobreviven al reinicio y a cambios de la biblioteca", async () => {
  let store = await space.open();
  const audio = space.path("sample.wav");
  write(audio, "synthetic audio");
  const recording = obj(await store.import(audio));
  const job = { id: "job-1", recordingId: recording.id, state: "queued", stage: "Transcribiendo", attempt: 2 };
  await store.jobSave(job);
  await store.mutate("log", { message: "other change" });
  assert.deepEqual(await store.jobs(), [job]);
  store = await reopen(space, store);
  assert.deepEqual(await store.jobs(), [job]);
  await store.jobRemove("job-1");
  assert.deepEqual(await store.jobs(), []);
});

test("memorias y trazas sobreviven al reinicio sin entrar en el snapshot", async () => {
  const audio = space.path("sample.wav");
  write(audio, "synthetic audio");
  let store = await space.open();
  const recordingId = str(obj(await store.import(audio)).id);
  const versionId = str(obj(await store.mutate("version_save", { recordingId, transcript: { text: "hola", segments: [] } })).id);
  const answer = { value: { answer: "respuesta" } };
  await store.memoryKeep(recordingId, versionId, "fingerprint-1", answer);
  await store.traceSave({ recordingId, recipeId: "default", startedAt: "2026-10-01T00:00:00Z", finishedAt: "2026-10-01T00:00:01Z", steps: [] });
  assert.deepEqual(await store.memoryRecall(recordingId, versionId, "fingerprint-1"), answer);
  assert.equal((await store.traceList(recordingId)).length, 1);
  assert.ok(!JSON.stringify(await store.snapshot()).includes("fingerprint-1"));
  store = await reopen(space, store);
  assert.deepEqual(await store.memoryRecall(recordingId, versionId, "fingerprint-1"), answer);
  assert.equal((await store.traceList(recordingId)).length, 1);
});

test("borrar una grabación limpia audio propio, memoria y trazas pero no el origen", async () => {
  const source = space.path("sample.wav");
  write(source, "synthetic audio");
  let store = await space.open();
  const recordingId = str(obj(await store.import(source)).id);
  const copy = store.audio(recordingId);
  const versionId = str(obj(await store.mutate("version_save", { recordingId, transcript: { text: "hola", segments: [] } })).id);
  await store.memoryKeep(recordingId, versionId, "fingerprint-1", { value: "x" });
  await store.traceSave({ recordingId, startedAt: "2026-10-01T00:00:00Z", steps: [] });
  await store.jobSave({ id: "job-active", recordingId, state: "running" });
  await store.mutate("recording_delete", { id: recordingId });
  await assert.rejects(store.recording(recordingId));
  assert.ok(!existsSync(copy));
  assert.equal(readFileSync(source, "utf8"), "synthetic audio");
  assert.deepEqual(await store.traceList(recordingId), []);
  assert.deepEqual(await store.jobs(), []);
  store = await reopen(space, store);
  await assert.rejects(store.recording(recordingId));
  assert.deepEqual(await store.traceList(recordingId), []);
  assert.deepEqual(await store.jobs(), []);
  assert.equal(await store.database.recall(JSON.stringify([recordingId, versionId, "fingerprint-1"])), undefined);
});

test("un fichero vacío es visible y se reactiva cuando llega el audio", async () => {
  const path = space.path("late.wav");
  write(path, "");
  const store = await space.open();
  const failed = obj(await store.mutate("recording_abandoned", { path }));
  assert.equal(failed.status, "failed");
  assert.equal(failed.audioPath, null);
  write(path, "synthetic audio");
  const recovered = obj(await store.import(path));
  assert.equal(recovered.id, failed.id);
  assert.equal(recovered.status, "pending");
  assert.equal(arr(obj(await store.dataJson()).recordings).length, 1);
});

test("una nota de voz vacía se recupera tras renombrarse por su clave de origen", async () => {
  const old = space.path("empty.m4a");
  write(old, "");
  const store = await space.open();
  const failed = obj(await store.mutate("recording_abandoned", { path: old, sourceKey: "voiceMemos:folder/42", title: "Sin audio" }));
  const renamed = space.path("complete.m4a");
  renameSync(old, renamed);
  write(renamed, "synthetic audio");
  const restored = obj(await store.importWithMetadata(renamed, undefined, "Con audio", new Date(), "voiceMemos:folder/42"));
  assert.equal(restored.id, failed.id);
  assert.equal(restored.status, "pending");
  assert.equal(restored.title, "Con audio");
  assert.equal(arr(obj(await store.dataJson()).recordings).length, 1);
});

test("importa el JSON del experimento anterior una vez y lo deja intacto", async () => {
  mkdirSync(space.library, { recursive: true });
  const previous = obj(JSON.parse(JSON.stringify((await import("../../../src/runtime/library/store")).defaults())));
  obj(previous.settings).language = "gl";
  previous.logs = [{ id: "old-log", at: "2026-10-01T00:00:00Z", message: "original", level: "info" }];
  const bytes = JSON.stringify(previous);
  write(join(space.library, "library.json"), bytes);
  let store = await space.open();
  assert.equal(obj(obj(await store.dataJson()).settings).language, "gl");
  await store.mutate("settings_save", { settings: { launchAtLogin: true } });
  await space.close(store);
  assert.equal(readFileSync(join(space.library, "library.json"), "utf8"), bytes);
  store = await space.open();
  assert.equal(obj(obj(await store.dataJson()).settings).language, "gl");
  assert.equal(obj(obj(await store.dataJson()).settings).launchAtLogin, true);
  const lines = await store.logList({});
  assert.equal(obj(lines[0]).message, "original");
  assert.equal(lines.length, 1);
});

test("quitar una cuenta quita su credencial", async () => {
  const store = await space.open();
  const account = { collection: "accounts", item: { id: "notion", name: "Notion", provider: "notion", enabled: true } };
  await store.mutate("config_save", account);
  await secrets(space.library).save("notion", "synthetic-secret");
  await store.mutate("config_remove", { collection: "accounts", id: "notion" });
  await store.mutate("config_save", account);
  assert.equal(store.credential("notion"), undefined);
});

test("guardar una receta o un destino sin su programa conserva el compilado", async () => {
  const store = await space.open();
  await store.mutate("config_save", { collection: "recipes", item: { id: "resumen", name: "Resumen", kind: "code", values: {}, bundle: "var __recipe = 1;" } });
  await store.mutate("config_save", { collection: "recipes", item: { id: "resumen", name: "Resumen", kind: "code", values: { idioma: "en" }, bundleFingerprint: "abc" } });
  const saved = store.item("recipes", "resumen");
  assert.equal(saved.bundle, "var __recipe = 1;");
  assert.equal(obj(saved.values).idioma, "en");
  assert.equal(saved.bundleFingerprint, undefined);
});

test("quitar conector borra cuenta, destino, token y valores sin borrar publicaciones", async () => {
  const store = await space.open();
  await store.mutate("config_save", { collection: "accounts", item: { id: "conector", name: "Notion", provider: "notion", enabled: true } });
  await store.mutate("config_save", { collection: "destinations", item: { id: "conector", name: "Notion", provider: "notion", account: "conector", enabled: true, configuration: {} } });
  await secrets(space.library).save("conector", "synthetic-token");
  await store.mutate("config_save", { collection: "recipes", item: { id: "form", name: "Form", kind: "form", values: { conectores: ["conector", "otro"] } } });
  const audio = space.path("sample.wav");
  write(audio, "synthetic audio");
  const record = obj(await store.import(audio));
  await store.mutate("publication_save", { recordingId: record.id, destinationId: "conector", accountId: "conector", receipt: { locator: "page-1", state: "published" } });
  await store.removeConnector("conector");
  assert.throws(() => store.item("accounts", "conector"));
  assert.throws(() => store.item("destinations", "conector"));
  assert.equal(store.credential("conector"), undefined);
  assert.deepEqual(obj(store.item("recipes", "form").values).conectores, ["otro"]);
  assert.equal(obj(obj(arr((await store.recording(str(record.id))).publications)[0]!.receipt)).locator, "page-1");
});

test("guardar conector persiste cuenta y destino juntos y rechaza pareja incoherente", async () => {
  const folder = space.path("bundle");
  mkdirSync(folder);
  let store = await space.open();
  const account = { id: "connector", name: "OKF", provider: "okf", enabled: true, folder, hasCredential: true };
  const destination = { id: "connector", name: "OKF", provider: "okf", account: "connector", enabled: false, configuration: { folder, documents: [] } };
  await store.saveConnector(account, destination);
  const canonical = realpathSync(folder);
  assert.equal(store.item("accounts", "connector").folder, canonical);
  assert.equal(obj(store.item("destinations", "connector").configuration).folder, canonical);
  assert.equal(store.item("accounts", "connector").hasCredential, undefined);
  assert.equal(store.item("destinations", "connector").account, "connector");
  await store.saveConnector({ ...account, enabled: false }, destination);
  assert.equal(store.item("accounts", "connector").enabled, false);
  const before = await store.dataJson();
  await assert.rejects(store.saveConnector(account, { id: "wrong", name: "OKF", provider: "okf", account: "connector", configuration: {} }));
  await assert.rejects(store.saveConnector(account, { id: "connector", name: "OKF", provider: "notion", account: "connector", configuration: {} }));
  assert.deepEqual(await store.dataJson(), before);
  store = await reopen(space, store);
  assert.equal(store.item("accounts", "connector").name, "OKF");
  assert.equal(store.item("destinations", "connector").provider, "okf");
});

test("cuenta Notion desconectada conserva la revocación", async () => {
  const store = await space.open();
  await store.saveConnector({ id: "notion-test", name: "Notion", provider: "notion", enabled: false }, { id: "notion-test", name: "Notion", provider: "notion", account: "notion-test", enabled: false, configuration: {} });
  const saved = store.item("accounts", "notion-test");
  assert.equal(saved.enabled, false);
  assert.throws(() => authorizedAccess(saved, undefined, {}, "http"));
});

test("una escritura fallida de la biblioteca conserva la copia de audio", async () => {
  const audio = space.path("sample.wav");
  write(audio, "synthetic audio");
  const store = await space.open();
  const key = str(obj(await store.import(audio)).id);
  const saved = store.audio(key);
  await store.database.queryTest("DEFINE FIELD OVERWRITE payload ON TABLE recording ASSERT !string::contains(<string> $value, '\"audioPath\":null') AND !string::contains(<string> $value, 'audioPath: NULL')");
  await assert.rejects(store.mutate("recording_remove_audio", { id: key }));
  assert.ok(existsSync(saved));
  assert.equal(store.audio(key), saved);
});

test("actualizar olvida recetas antiguas una vez y conserva elecciones nuevas", async () => {
  mkdirSync(space.library, { recursive: true });
  const legacy = obj(JSON.parse(JSON.stringify((await import("../../../src/runtime/library/store")).defaults())));
  legacy.recordings = [{ id: "anterior", source: "/synthetic/old.wav", status: "done", recipeId: "receta-antigua", publications: [], versions: [{ id: "version-anterior", recipeId: "receta-ejecutada", transcript: { text: "ejemplo", segments: [] } }] }];
  write(join(space.library, "library.json"), JSON.stringify(legacy));
  let store = await space.open();
  const previous = await store.recording("anterior");
  assert.equal(previous.recipeId, null);
  assert.equal(arr(previous.versions)[0]!.recipeId, "receta-ejecutada");
  const audio = space.path("nueva.wav");
  write(audio, "eleccion nueva sintetica");
  const added = obj(await store.import(audio, "elegida-despues"));
  store = await reopen(space, store);
  assert.equal((await store.recording("anterior")).recipeId, null);
  assert.equal((await store.recording(str(added.id))).recipeId, "elegida-despues");
});

test("rechaza una segunda instancia sin sustituir datos", async () => {
  await space.open(space.dir);
  await assert.rejects(Store.open(space.dir), /ya está abierta/);
});

test("los ajustes rechazan tipos inválidos sin cambiar la biblioteca", async () => {
  const store = await space.open(space.dir);
  const before = await store.snapshot();
  await assert.rejects(store.mutate("settings_save", { settings: { notifyEveryNote: "sí" } }));
  assert.deepEqual(await store.snapshot(), before);
});

test("las opciones retiradas no se modifican aunque estuvieran guardadas", async () => {
  const store = await space.open(space.dir);
  const before = obj(await store.dataJson()).settings;
  await store.mutate("settings_save", { settings: { language: "en", theme: "dark", autoProcess: false, recipeSelectionMigrated: false } });
  assert.deepEqual(obj(await store.dataJson()).settings, before);
  assert.deepEqual(SETTABLE.length, 7);
});

test("no confirma entidades corruptas ni pierde el estado anterior", async () => {
  const store = await space.open(space.dir);
  const before = await store.snapshot();
  const next = obj(await store.dataJson());
  next.recordings = [{ id: "rota", status: "done", versions: [{ id: "v", transcript: { text: 42, segments: [] } }] }];
  await assert.rejects(store.replace(next));
  assert.deepEqual(await store.snapshot(), before);
});

test("las versiones conservan campos extensibles, nulos y ausentes al reabrir", async () => {
  const source = space.path("sintetico.wav");
  write(source, "audio sintetico");
  let store = await space.open();
  const record = obj(await store.import(source));
  const version = obj(await store.mutate("version_save", { recordingId: record.id, transcript: { text: "sintetico", segments: [{ text: "sintetico", start: 0, end: 1.5, speaker: null, words: [{ text: "sintetico", start: 0, end: 1.5, confidence: 0.95 }], custom: true }], language: "es", recognitions: null, custom: { nested: null } }, digest: null, data: { custom: 42 }, inputs: null }));
  const data = obj(await store.dataJson());
  arr(data.recordings)[0]!.custom = { legitimate: true };
  arr(arr(data.recordings)[0]!.versions)[0]!.dataSchema = { type: "object" };
  await store.replace(data);
  await store.mutate("version_select", { recordingId: record.id, versionId: version.id });
  assert.deepEqual(await store.dataJson(), data);
  store = await reopen(space, store);
  assert.deepEqual(await store.dataJson(), data);
  const detail = await store.recording(str(record.id));
  assert.equal(arr(detail.versions)[0]!.recipeId, undefined);
  assert.equal(arr(detail.versions)[0]!.digest, null);
  assert.deepEqual(arr(detail.versions)[0]!.transcript, version.transcript);
});

test("la biblioteca tipificada conserva la vista ligera sin texto completo ni programas", async () => {
  const store = await space.open(space.dir);
  const data = obj(await store.dataJson());
  data.recordings = [{ id: "nota", status: "done", title: "sintetico", duration: 1, versions: [{ id: "v", backend: "test", transcript: { text: "x".repeat(500), segments: [{ text: "x", start: 0, end: 1, words: [{ text: "x", start: 0, end: 1 }] }], language: "es" } }], publications: [] }];
  arr(data.recipes)[0]!.bundle = "programa sintetico".repeat(1000);
  await store.replace(data);
  const typed = readLibraryData(await store.dataJson());
  for (const record of typed.recordings) {
    record.versions = (record.versions ?? []).map(previewVersion);
    record.publications = (record.publications ?? []).map(lightPublication);
  }
  const expected = typedLibrary(typed);
  expected.settings = redactedSettings(expected.settings);
  expected.dataPath = store.root;
  markCredentials(store.root, expected);
  assert.deepEqual(store.library(), expected);
  assert.equal(str(obj(obj(arr(arr(store.library().recordings)[0]!.versions)[0]!).transcript).text).length, 400);
  assert.equal(arr(store.library().recipes)[0]!.bundle, undefined);
  assert.deepEqual(libraryView(store.data, store.root), store.library());
});

test("una operación de cuenta incierta sobrevive a la reapertura hasta resolverse a mano", async () => {
  const audio = space.path("synthetic.wav");
  write(audio, "synthetic audio");
  let store = await space.open();
  const id = str(obj(await store.import(audio)).id);
  await store.mutate("account_effect_begin", { recordingId: id });
  assert.equal((await store.recording(id)).accountEffectPending, true);
  assert.equal(arr((await store.runtimeContext(id)).recordings)[0]!.accountEffectPending, true);
  store = await reopen(space, store);
  assert.equal((await store.recording(id)).accountEffectPending, true);
  await store.mutate("account_effect_finish", { recordingId: id });
  assert.equal((await store.recording(id)).accountEffectPending, undefined);
  assert.equal(arr((await store.runtimeContext(id)).recordings)[0]!.accountEffectPending, false);
});

async function drainKnowledge(store: Store): Promise<string[]> {
  const changed: string[] = [];
  for (;;) {
    const change = await store.knowledgeChange();
    if (!change) return changed;
    changed.push(change.id);
    await store.knowledgeAck(change.key, change.revision);
  }
}
async function syntheticLibrary(count: number) {
  const store = await space.open();
  const ids: string[] = [];
  for (let index = 0; index < count; index++) {
    const audio = space.path(`nota-${index}.wav`);
    write(audio, `audio sintético ${index}`);
    ids.push(str(obj(await store.import(audio)).id));
  }
  await drainKnowledge(store);
  return { store, ids };
}

test("incorporar una nota solo reescribe esa nota", async () => {
  const { store, ids } = await syntheticLibrary(12);
  const audio = space.path("nueva.wav");
  write(audio, "audio sintetico nuevo");
  const recording = obj(await store.import(audio));
  assert.deepEqual(await drainKnowledge(store), [recording.id]);
  await store.mutate("recording_update", { id: ids[5], title: "Otro título" });
  assert.deepEqual(await drainKnowledge(store), [ids[5]]);
});

test("registrar una línea no toca la biblioteca y se lee aparte", async () => {
  const { store, ids } = await syntheticLibrary(3);
  await store.mutate("log", { message: "primera", level: "warn", recordingId: ids[1] });
  await store.mutate("log", { message: "segunda" });
  assert.deepEqual(await drainKnowledge(store), []);
  assert.equal(store.library().logs, undefined);
  assert.equal((await store.snapshot()).logs, undefined);
  const lines = arr(await store.logList({}));
  assert.deepEqual(lines.map((line) => line.message), ["segunda", "primera"]);
  const only = arr(await store.logList({ recordingId: ids[1] }));
  assert.equal(only.length, 1);
  assert.equal(only[0]!.level, "warn");
  const older = arr(await store.logList({ before: lines[0]!.at, limit: 5 }));
  assert.equal(older[0]!.message, "primera");
  await assert.rejects(store.mutate("log", { message: "x", level: "grave" }));
  await assert.rejects(store.logList({ desconocido: true }));
});

test("los registros anteriores se leen por fecha sin reescribirse", async () => {
  let store = await space.open();
  for (const [position, [id, at]] of [["antigua", "2026-10-01T08:00:00+00:00"], ["reciente", "2026-10-03T08:00:00+00:00"], ["media", "2026-10-02T08:00:00+00:00"]].entries())
    await store.database.queryTest(`CREATE log:${id} SET key = '${id}', parent = '', position = ${position}, payload = { id: '${id}', at: '${at}', message: '${id}', level: 'info' }`);
  store = await reopen(space, store);
  const lines = arr(await store.logList({}));
  assert.deepEqual(lines.map((line) => line.id), ["reciente", "media", "antigua"]);
  assert.equal(store.library().logs, undefined);
});

test("el registro conserva las últimas líneas", async () => {
  let store = await space.open();
  const total = LOG_RETAINED + 70;
  await store.database.queryTest(`FOR $index IN 0..${total} { LET $id = 'l' + <string> $index; CREATE type::record('log', $id) SET key = $id, parent = '', position = 0, payload = { id: $id, at: '2026-10-11T00:00:00.' + string::slice('000000' + <string> $index, -6) + '+00:00', message: 'línea', level: 'info' }; }`);
  store = await reopen(space, store);
  const stored = await store.database.selectTest("SELECT key FROM log");
  assert.ok(stored.length <= LOG_RETAINED);
  const lines = arr(await store.logList({}));
  assert.equal(lines[0]!.id, `l${total - 1}`);
});

test("la lista ordena por fecha al reabrir aunque se incorpore fuera de orden", async () => {
  let store = await space.open();
  for (const [name, day] of [["b", 2], ["c", 3], ["a", 1]] as [string, number][]) {
    const audio = space.path(`${name}.m4a`);
    write(audio, `audio ${name}`);
    await store.importWithMetadata(audio, undefined, name, seconds(1_790_000_000 + day * 86_400), `clave-${name}`);
  }
  store = await reopen(space, store);
  assert.deepEqual(store.data.recordings.map((record) => record.title), ["c", "b", "a"]);
});

test("preparar el audio no toca la biblioteca y limpia su copia", async () => {
  const { store } = await syntheticLibrary(0);
  const audio = space.path("preparada.wav");
  write(audio, "audio sintetico preparado");
  const temporaries = () => readdirSync(join(store.root, "audio")).filter((name) => name.endsWith(".import")).length;
  let staged = stageAudio(store.root, audio, false);
  assert.equal(temporaries(), 1);
  assert.deepEqual(await drainKnowledge(store), []);
  const other = space.path("otra.wav");
  write(other, "otro audio");
  await assert.rejects(store.importStaged(staged, other));
  assert.equal(temporaries(), 0);
  staged = stageAudio(store.root, audio, false);
  const record = obj(await store.importStaged(staged, audio));
  assert.equal(temporaries(), 0);
  assert.equal((await store.recording(str(record.id))).status, "pending");
  stageAudio(store.root, audio, false).discard();
  assert.equal(temporaries(), 0);
});

test("un modelo de Whisper añadido es un resolutor local que se puede quitar", async () => {
  const store = await space.open();
  const added = obj(await store.mutate("config_save", { collection: "resolvers", item: { id: "local-stt-base", name: "Whisper · base", role: "stt", model: "base", local: false, enabled: false } }));
  assert.equal(added.local, true);
  assert.equal(added.enabled, true);
  assert.equal(store.item("resolvers", "local-stt-base").model, "base");
  const ids = arr(obj(await store.snapshot()).resolvers).map((resolver) => resolver.id);
  assert.equal(ids[0], "local-stt");
  assert.equal(ids.at(-1), "local-stt-base");
  await assert.rejects(store.mutate("config_save", { collection: "resolvers", item: { id: "local-stt-base", name: "x", role: "stt", model: "small" } }), /modelo/);
  await assert.rejects(store.mutate("config_save", { collection: "resolvers", item: { id: "local-stt-base", name: "x", role: "llm", model: "base" } }), /modelo/);
  await store.mutate("config_remove", { collection: "resolvers", id: "local-stt-base" });
  assert.throws(() => store.item("resolvers", "local-stt-base"));
});

test("el Whisper de serie se puede quitar; Apple Intelligence y la receta por defecto no", async () => {
  const store = await space.open();
  await store.mutate("config_remove", { collection: "resolvers", id: "local-stt" });
  assert.throws(() => store.item("resolvers", "local-stt"));
  const reopened = await reopen(space, store);
  assert.throws(() => reopened.item("resolvers", "local-stt"));
  await assert.rejects(reopened.mutate("config_remove", { collection: "resolvers", id: "local-llm" }), /de serie/);
  await assert.rejects(reopened.mutate("config_remove", { collection: "recipes", id: "default" }), /de serie/);
});
