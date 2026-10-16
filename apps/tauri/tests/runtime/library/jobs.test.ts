import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Library } from "../../../src/runtime/library/library";
import { Queue } from "../../../src/runtime/library/queue";
import {
  expired, historyDays, historyPage, loadOne, nextInLane, recipeFor, relaunchArgs, retryable, save, stampTrace, traceOwner,
  type HistoryQuery, type Job, type JobOperation, type JobState,
} from "../../../src/runtime/library/jobs";
import { arr, obj, str } from "./fixture";

let dir = "";
let opened: Library[] = [];
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "escriba-jobs-"));
});
afterEach(async () => {
  for (const library of opened.splice(0)) await library.close().catch(() => undefined);
  await rm(dir, { recursive: true, force: true });
});
async function library(root = join(dir, "library")) {
  const opened_ = await Library.open(root);
  opened.push(opened_);
  return opened_;
}
async function closeLibrary(target: Library) {
  await target.close();
  opened.splice(opened.indexOf(target), 1);
}
async function imported(store: Library, name: string) {
  const path = join(dir, name);
  writeFileSync(path, name);
  return obj(await store.withStore((inner) => inner.import(path)));
}
const job = (id: string, recording: string, operation: JobOperation, state: JobState, created: number): Job => ({
  id, recordingId: recording, operation, args: {}, automatic: false, audioHash: null, recipe: null, state, stage: "", attempt: 0,
  createdAt: created, startedAt: created, finishedAt: null, nextAttemptAt: 0, error: null, errorCode: null, result: null, extra: {},
});
const finished = (id: string, operation: JobOperation, state: JobState, ended: number, recipe?: [string, string]): Job => ({
  ...job(id, `nota-${id}`, operation, state, ended - 10),
  finishedAt: ended,
  recipe: recipe ? { id: recipe[0], name: recipe[1] } : null,
});
const history = async (queue: Queue) => (await queue.history({ limit: 1000 })).jobs;
const ok = (value: unknown = null) => ({ ok: true as const, value: value as never });
const failure = (code: "failed" | "backend_unavailable", message: string) => ({ ok: false as const, error: { code, message } });

test("una transcripción en curso no retiene la publicación de otra nota", () => {
  const jobs = [job("t", "a", "processRecording", "running", 1), job("t2", "c", "processRecording", "queued", 2), job("p", "b", "publishRecording", "queued", 3)];
  assert.equal(nextInLane(jobs, "inference", 10), undefined);
  assert.equal(nextInLane(jobs, "io", 10), 2);
});

test("el carril de red admite tres y respeta esperas y orden", () => {
  const jobs = Array.from({ length: 4 }, (_, index) => job(`p${index}`, `r${index}`, "publishRecording", "queued", 10 - index));
  assert.equal(nextInLane(jobs, "io", 100), 3);
  for (const running of jobs.slice(1)) running.state = "running";
  assert.equal(nextInLane(jobs, "io", 100), undefined);
  jobs[3]!.state = "retry";
  jobs[3]!.nextAttemptAt = 500;
  assert.equal(nextInLane(jobs, "io", 100), 0);
  jobs[0]!.nextAttemptAt = 200;
  jobs[0]!.state = "retry";
  assert.equal(nextInLane(jobs, "io", 100), undefined);
  assert.equal(nextInLane(jobs, "io", 600), 3);
});

test("nunca corren dos trabajos de la misma nota", () => {
  const jobs = [job("t", "a", "processRecording", "running", 1), job("p", "a", "publishRecording", "queued", 2)];
  assert.equal(nextInLane(jobs, "io", 10), undefined);
});

test("publicar otra nota no espera a la transcripción", async () => {
  const store = await library();
  const ids = [str((await imported(store, "una.wav")).id), str((await imported(store, "otra.wav")).id)];
  const queue = await Queue.open(store);
  await queue.enqueue("processRecording", { recordingId: ids[0] });
  assert.ok(await queue.claim("inference"));
  const publish = await queue.enqueue("publishRecording", { recordingId: ids[1], destinationId: "d" });
  assert.equal(obj(await queue.claim("io")).id, publish);
  assert.equal(await queue.claim("inference"), undefined);
  assert.equal(queue.visible().length, 2);
});

test("cancelar una publicación no corta la inferencia de otra nota", async () => {
  const store = await library();
  const ids = [str((await imported(store, "una.wav")).id), str((await imported(store, "otra.wav")).id)];
  const queue = await Queue.open(store);
  await queue.enqueue("processRecording", { recordingId: ids[0] });
  assert.ok(await queue.claim("inference"));
  const publish = await queue.enqueue("publishRecording", { recordingId: ids[1], destinationId: "d" });
  assert.ok(await queue.claim("io"));
  const publication = await queue.cancel(ids[1]!);
  assert.deepEqual(publication.ids, [publish]);
  assert.ok(!publication.inference);
  assert.ok((await queue.cancel(ids[0]!)).inference);
});

test("un trabajo automático no repite un efecto externo incierto", async () => {
  const store = await library();
  const record = await imported(store, "synthetic.wav");
  await store.mutate("account_effect_begin", { recordingId: record.id });
  const queue = await Queue.open(store);
  const id = await queue.enqueueAutomatic(str(record.id));
  assert.equal(await queue.claim("inference"), undefined);
  const failed = (await history(queue)).find((item) => item.id === id)!;
  assert.equal(failed.state, "failed");
  assert.ok(failed.finishedAt !== null);
  assert.ok(failed.error!.includes("Revisa la operación externa"));
});

test("un trabajo manual recuperado no repite un efecto externo incierto", async () => {
  const store = await library();
  const record = await imported(store, "synthetic.wav");
  const queue = await Queue.open(store);
  const id = await queue.enqueue("processRecording", { recordingId: record.id, options: { force: true } });
  assert.ok(await queue.claim("inference"));
  await store.mutate("account_effect_begin", { recordingId: record.id });
  await queue.finish(id, failure("backend_unavailable", "temporary"));
  await store.withStore(async (inner) => {
    const waiting = (await loadOne(inner.database, id))!;
    waiting.nextAttemptAt = 0;
    await save(inner, waiting);
  });
  assert.equal(await queue.claim("inference"), undefined);
  assert.equal((await history(queue)).find((item) => item.id === id)!.state, "failed");
});

test("cancelar tras la inferencia impide confirmar el resultado y avisar del éxito", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  const id = await queue.enqueueAutomatic(str(record.id));
  assert.ok(await queue.claim("inference"));
  await queue.cancel(str(record.id));
  assert.ok(!(await queue.finish(id, ok())));
});

test("un trabajo interrumpido se reanuda sin crear otra versión manual", async () => {
  const root = join(dir, "library");
  let store = await library(root);
  const record = await imported(store, "note.wav");
  let queue = await Queue.open(store);
  const id = await queue.enqueue("processRecording", { recordingId: record.id, options: { force: true } });
  assert.equal(obj(await queue.claim("inference")).attempt, 1);
  await closeLibrary(store);
  store = await library(root);
  queue = await Queue.open(store);
  const resumed = obj(await queue.claim("inference"));
  assert.equal(resumed.id, id);
  assert.equal(resumed.attempt, 2);
  assert.equal(obj(obj(resumed.args).options).force, false);
  assert.equal(resumed.automatic, false);
});

test("el origen automático se conserva al recuperar un trabajo", async () => {
  const root = join(dir, "library");
  let store = await library(root);
  await imported(store, "note.wav");
  let queue = await Queue.open(store);
  await queue.automatic();
  const first = obj(await queue.claim("inference"));
  assert.equal(first.automatic, true);
  await closeLibrary(store);
  store = await library(root);
  queue = await Queue.open(store);
  const resumed = obj(await queue.claim("inference"));
  assert.equal(resumed.id, first.id);
  assert.equal(resumed.automatic, true);
});

test("los servicios no disponibles reintentan pero una entrada mala no", () => {
  assert.ok(retryable("backend_unavailable"));
  assert.ok(!retryable("failed"));
});

test("un trabajo legacy en espera conserva el código al reabrir", async () => {
  const root = join(dir, "library");
  let store = await library(root);
  const recording = await imported(store, "synthetic.wav");
  await store.withStore((inner) => inner.jobSave({ id: "old-job", recordingId: recording.id, operation: "processRecording", args: { recordingId: recording.id }, state: "retry", stage: "Esperando al servicio", attempt: 1, createdAt: 1, startedAt: 1, nextAttemptAt: Number.MAX_SAFE_INTEGER, error: "BACKEND_UNAVAILABLE: modelo ausente", externalReceipt: { id: "receipt" } }));
  await closeLibrary(store);
  store = await library(root);
  const queue = await Queue.open(store);
  const old = obj(queue.visible()[0]);
  assert.equal(old.id, "old-job");
  assert.equal(old.state, "retry");
  assert.equal(old.errorCode, "backend_unavailable");
  await queue.cancel(str(recording.id));
  const saved = (await history(queue)).find((item) => item.id === "old-job")!;
  assert.equal(obj(saved.extra.externalReceipt).id, "receipt");
});

test("un servicio en espera no retiene la siguiente grabación", async () => {
  const store = await library();
  const recordings = [await imported(store, "one.wav"), await imported(store, "two.wav")];
  const queue = await Queue.open(store);
  const first = await queue.enqueue("processRecording", { recordingId: recordings[0]!.id });
  await queue.enqueue("processRecording", { recordingId: recordings[1]!.id });
  assert.equal(obj(await queue.claim("inference")).id, first);
  await queue.finish(first, failure("backend_unavailable", "429"));
  assert.equal(obj(await queue.claim("inference")).recordingId, recordings[1]!.id);
  assert.equal((await store.recording(str(recordings[0]!.id))).status, "pending");
});

test("un fallo, una espera o una cancelación no cambian el estado de una nota ya transcrita", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const id = str(record.id);
  await store.withStore(async (inner) => {
    await inner.mutate("version_save", { recordingId: id, transcript: { text: "sintético", segments: [] } });
    await inner.mutate("recording_update", { id, status: "done", error: null });
  });
  const queue = await Queue.open(store);
  for (const result of [failure("backend_unavailable", "LLM caído"), failure("failed", "Resumen vacío")]) {
    const next = await queue.enqueue("processRecording", { recordingId: id, options: { recipeId: "serie:resumir", force: true } });
    await queue.claim("inference");
    await queue.finish(next, result);
    if (result.error.code === "backend_unavailable") await queue.cancel(id);
    assert.equal((await store.recording(id)).status, "done");
  }
});

test("una prueba fallida conserva la grabación y no desactiva el trabajo automático", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  const id = await queue.enqueue("processRecording", { recordingId: record.id, options: { dryRun: true } });
  await queue.claim("inference");
  await queue.finish(id, failure("failed", "Receta inválida"));
  assert.deepEqual(await store.recording(str(record.id)), record);
  await queue.automatic();
  const next = obj(await queue.claim("inference"));
  assert.notEqual(next.id, id);
  assert.equal(obj(obj(next.args).options).force, false);
});

test("un audio cambiado se encola otra vez tras una ejecución completada", async () => {
  const store = await library();
  const audio = join(dir, "note.wav");
  writeFileSync(audio, "first contents");
  const started = new Date();
  const metadata = () => store.withStore((inner) => inner.importWithMetadata(audio, undefined, "Nota", started, "voiceMemos:test/1"));
  const record = obj(await metadata());
  const queue = await Queue.open(store);
  await queue.automatic();
  const claimed = obj(await queue.claim("inference"));
  await queue.finish(str(claimed.id), ok());
  writeFileSync(audio, "changed contents");
  await metadata();
  await queue.automatic();
  const next = obj(await queue.claim("inference"));
  assert.equal(next.recordingId, record.id);
  assert.notEqual(next.audioHash, claimed.audioHash);
});

test("la receta de un trabajo sigue la misma prioridad que el runtime", () => {
  const recipes = [{ id: "default", name: "Por defecto" }, { id: "resumen", name: "Resumen" }];
  const resumen = { id: "resumen", name: "Resumen" };
  assert.deepEqual(recipeFor({ options: { recipeId: "resumen" } }, "default", "default", recipes), resumen);
  assert.deepEqual(recipeFor({}, "resumen", "default", recipes), resumen);
  assert.deepEqual(recipeFor({ options: { recipeId: "" } }, null, "resumen", recipes), resumen);
  assert.deepEqual(recipeFor({}, null, "Resumen", recipes), resumen);
  assert.deepEqual(recipeFor({}, "borrada", "default", recipes), { id: "borrada", name: "borrada" });
  assert.equal(recipeFor({}, null, null, recipes), null);
});

const page = (jobs: Job[], query: HistoryQuery) => {
  const result = historyPage(jobs, query);
  return [result.jobs.map((item) => item.id), result.next] as const;
};

test("el historial va del más reciente al más antiguo sin los activos", () => {
  const legacy = job("antiguo", "nota", "publishRecording", "succeeded", 25);
  legacy.startedAt = 25;
  const jobs = [
    finished("a", "processRecording", "succeeded", 10), job("activo", "x", "processRecording", "running", 50), job("cola", "y", "publishRecording", "queued", 60),
    job("espera", "z", "processRecording", "retry", 70), finished("c", "processRecording", "failed", 30), legacy, finished("b", "summarizeRecording", "cancelled", 20),
  ];
  assert.deepEqual(page(jobs, { limit: 100 })[0], ["c", "antiguo", "b", "a"]);
});

test("el historial se carga por páginas sin repetir ni saltarse ninguno", () => {
  const jobs = Array.from({ length: 250 }, (_, index) => finished(`j${String(index).padStart(3, "0")}`, "processRecording", "succeeded", 1000 + Math.floor(index / 2)));
  const seen: string[] = [];
  let cursor: HistoryQuery["before"];
  let pages = 0;
  for (;;) {
    const [ids, next] = page(jobs, { limit: 100, ...(cursor ? { before: cursor } : {}) });
    pages += 1;
    assert.ok(ids.length <= 100);
    seen.push(...ids);
    if (!next) break;
    cursor = next;
  }
  assert.equal(pages, 3);
  assert.deepEqual(seen, Array.from({ length: 250 }, (_, index) => `j${String(index).padStart(3, "0")}`).reverse());
});

test("el historial filtra por estado, receta y acción manual", () => {
  const jobs = [
    finished("ok", "processRecording", "succeeded", 50, ["resumen", "Resumen"]), finished("mal", "processRecording", "failed", 40, ["default", "Por defecto"]),
    finished("pub", "publishRecording", "failed", 30), finished("off", "unpublishRecording", "cancelled", 20), finished("viejo", "processRecording", "failed", 10, ["resumen", "Resumen antiguo"]),
  ];
  assert.deepEqual(page(jobs, { limit: 100, state: "failed" })[0], ["mal", "pub", "viejo"]);
  assert.deepEqual(page(jobs, { limit: 100, recipeId: "resumen" })[0], ["ok", "viejo"]);
  assert.deepEqual(page(jobs, { limit: 100, operation: "publishRecording" })[0], ["pub"]);
  assert.deepEqual(page(jobs, { limit: 100, state: "cancelled", operation: "publishRecording" }), [[], null]);
  assert.deepEqual(historyPage(jobs, { limit: 1 }).recipes, [{ id: "resumen", name: "Resumen" }, { id: "default", name: "Por defecto" }]);
});

test("el historial no acepta estados activos como filtro", () => {
  assert.deepEqual(historyPage([job("activo", "x", "processRecording", "running", 1)], { limit: 100, state: "running" }).jobs, []);
});

test("un trabajo guarda su receta y cuándo empezó y acabó", async () => {
  const store = await library();
  const id = str((await imported(store, "note.wav")).id);
  await store.mutate("config_save", { collection: "recipes", item: { id: "resumen", name: "Resumen", kind: "form", values: {} } });
  const queue = await Queue.open(store);
  const jobId = await queue.enqueue("processRecording", { recordingId: id });
  const queued = arr(queue.visible());
  assert.deepEqual(queued[0]!.recipe, { id: "default", name: "Por defecto" });
  assert.equal(queued[0]!.finishedAt, null);
  await store.mutate("recording_update", { id, recipeId: "resumen" });
  const before = Date.now();
  const running = obj(await queue.claim("inference"));
  assert.deepEqual(running.recipe, { id: "resumen", name: "Resumen" });
  assert.deepEqual(running.args, { recordingId: id, options: { baseVersionId: null, jobId } });
  assert.ok((running.startedAt as number) >= before);
  await queue.finish(jobId, ok());
  await store.mutate("config_save", { collection: "recipes", item: { id: "resumen", name: "Resumen corto", kind: "form", values: {} } });
  const done = (await history(queue))[0]!;
  assert.equal(done.state, "succeeded");
  assert.equal(done.recipe!.name, "Resumen");
  assert.ok(done.finishedAt! >= done.startedAt);
});

test("las acciones manuales no tienen receta y cancelar marca el final", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  await queue.enqueue("publishRecording", { recordingId: record.id, destinationId: "d" });
  assert.equal(obj(queue.visible()[0]).recipe, null);
  await queue.cancel(str(record.id));
  const cancelled = (await history(queue))[0]!;
  assert.equal(cancelled.state, "cancelled");
  assert.ok(cancelled.finishedAt !== null);
  assert.deepEqual(queue.visible(), []);
});

test("relanzar procesar repite la receta, los valores y la versión de partida del trabajo, y lo demás se repite", () => {
  const process = job("p", "nota", "processRecording", "failed", 1);
  process.args = { recordingId: "nota", options: { recipeId: "serie:resumir", values: { llm: "remoto" }, baseVersionId: "v4", jobId: "p", force: false } };
  assert.deepEqual(relaunchArgs(process), { recordingId: "nota", options: { recipeId: "serie:resumir", values: { llm: "remoto" }, baseVersionId: "v4", force: true } });
  const automatic = { ...process, args: { recordingId: "nota", options: { force: false } } };
  assert.deepEqual(relaunchArgs(automatic), { recordingId: "nota", options: { force: true } });
  const dry = { ...process, args: { recordingId: "nota", options: { recipeId: "nueva", dryRun: true } } };
  assert.deepEqual(relaunchArgs(dry), dry.args);
  const publish = job("u", "nota", "publishRecording", "cancelled", 1);
  publish.args = { recordingId: "nota", destinationId: "notion" };
  assert.deepEqual(relaunchArgs(publish), publish.args);
  const summary = job("s", "nota", "summarizeRecording", "failed", 1);
  summary.args = { recordingId: "nota", llm: "remoto" };
  assert.deepEqual(relaunchArgs(summary), summary.args);
});

test("cada intento de procesar lleva el id de su trabajo para escribir en la versión que ya creó", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  const id = await queue.enqueue("processRecording", { recordingId: record.id, options: { baseVersionId: "v1", force: true } });
  const first = obj(await queue.claim("inference"));
  assert.deepEqual(obj(first.args).options, { baseVersionId: "v1", force: true, jobId: id });
  await queue.finish(id, failure("backend_unavailable", "LLM caído"));
  await store.withStore((inner) => inner.jobSave({ ...(obj(first) as Record<string, unknown>), state: "retry", nextAttemptAt: 0 } as never));
  const retried = obj(await queue.claim("inference"));
  assert.deepEqual(obj(retried.args).options, { baseVersionId: "v1", force: false, jobId: id });
});

test("encolar procesar apunta la versión de partida: la vigente, la elegida o ninguna", async () => {
  const store = await library();
  const fresh = await imported(store, "nueva.wav");
  const transcribed = await imported(store, "vieja.wav");
  const v1 = str(obj(await store.mutate("version_save", { recordingId: transcribed.id, transcript: { text: "uno", segments: [] } })).id);
  await store.mutate("version_save", { recordingId: transcribed.id, transcript: { text: "dos", segments: [] } });
  await store.mutate("version_select", { recordingId: transcribed.id, versionId: v1 });
  const queue = await Queue.open(store);
  await queue.enqueue("processRecording", { recordingId: fresh.id, options: { force: false } });
  await queue.enqueue("processRecording", { recordingId: transcribed.id, options: { force: true } });
  const options = (recordingId: unknown) => obj(obj(arr(queue.visible()).find((item) => item.recordingId === recordingId)!.args).options);
  assert.equal(options(fresh.id).baseVersionId, null);
  assert.equal(options(transcribed.id).baseVersionId, v1);
  assert.equal(await queue.enqueue("processRecording", { recordingId: transcribed.id, options: { force: true } }), obj(arr(queue.visible()).find((item) => item.recordingId === transcribed.id)!).id);
});

async function failedJob(queue: Queue, operation: string, args: Record<string, unknown>) {
  const id = await queue.enqueue(operation, args as never);
  await queue.claim(operation === "publishRecording" ? "io" : "inference");
  await queue.finish(id, failure("failed", "Resumen vacío"));
  return id;
}

test("relanzar un fallido encola otro y conserva el original", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  const original = await failedJob(queue, "processRecording", { recordingId: record.id, options: { recipeId: "default", force: true } });
  const relaunched = await queue.relaunch(original);
  assert.notEqual(relaunched, original);
  const active = arr(queue.visible());
  assert.equal(active[0]!.id, relaunched);
  assert.equal(active[0]!.state, "queued");
  assert.equal(active[0]!.automatic, false);
  assert.deepEqual(active[0]!.args, { recordingId: record.id, options: { recipeId: "default", baseVersionId: null, force: true } });
  assert.equal(obj(active[0]!.recipe).id, "default");
  const kept = await history(queue);
  assert.equal(kept.length, 1);
  assert.equal(kept[0]!.id, original);
  assert.equal(kept[0]!.state, "failed");
  assert.equal(kept[0]!.error, "Resumen vacío");
});

test("solo se relanzan trabajos fallidos o cancelados", async () => {
  const store = await library();
  const ids = [str((await imported(store, "una.wav")).id), str((await imported(store, "otra.wav")).id)];
  const queue = await Queue.open(store);
  const queued = await queue.enqueue("processRecording", { recordingId: ids[0] });
  await assert.rejects(queue.relaunch(queued), /fallidos o cancelados/);
  assert.ok(await queue.claim("inference"));
  await assert.rejects(queue.relaunch(queued));
  await queue.finish(queued, ok());
  await assert.rejects(queue.relaunch(queued));
  const publish = await queue.enqueue("publishRecording", { recordingId: ids[1], destinationId: "notion" });
  await queue.cancel(ids[1]!);
  const again = await queue.relaunch(publish);
  assert.deepEqual(obj(queue.visible()[0]).args, { recordingId: ids[1], destinationId: "notion" });
  assert.notEqual(again, publish);
  await assert.rejects(queue.relaunch("desconocido"));
});

test("no se relanza si la nota tiene un trabajo activo", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  const failed = await failedJob(queue, "publishRecording", { recordingId: record.id, destinationId: "notion" });
  await queue.enqueue("processRecording", { recordingId: record.id });
  await assert.rejects(queue.relaunch(failed), /ya tiene un trabajo pendiente/);
  assert.equal(queue.visible().length, 1);
});

test("no se relanza con un efecto externo incierto pendiente", async () => {
  const store = await library();
  const record = await imported(store, "note.wav");
  const queue = await Queue.open(store);
  const failed = await failedJob(queue, "publishRecording", { recordingId: record.id, destinationId: "notion" });
  await store.mutate("account_effect_begin", { recordingId: record.id });
  await assert.rejects(queue.relaunch(failed), /Revisa la operación externa/);
  assert.deepEqual(queue.visible(), []);
});

const DAY = 86_400_000;

test("el plazo por defecto es una semana y siempre no borra nada", () => {
  assert.equal(historyDays(undefined), 7);
  assert.equal(historyDays(30), 30);
  assert.equal(historyDays(null), null);
});

test("solo caducan los terminados fuera de plazo y sin efecto pendiente", () => {
  const now = 100 * DAY;
  const cutoff = now - 7 * DAY;
  const jobs = [
    finished("viejo", "processRecording", "succeeded", cutoff - 1), finished("fallido", "publishRecording", "failed", cutoff - DAY), finished("cancelado", "summarizeRecording", "cancelled", cutoff - DAY),
    finished("reciente", "processRecording", "succeeded", cutoff + 1), finished("pendiente", "publishRecording", "failed", cutoff - DAY),
    job("activo", "nota-activo", "processRecording", "queued", 1), job("espera", "nota-espera", "processRecording", "retry", 1),
  ];
  const legacy = job("antiguo", "nota-antiguo", "processRecording", "succeeded", cutoff - DAY);
  legacy.startedAt = cutoff - DAY;
  jobs.push(legacy);
  assert.deepEqual(expired(jobs, cutoff, new Set(["nota-pendiente"])).sort(), ["antiguo", "cancelado", "fallido", "viejo"]);
});

test("el plazo solo admite siete, treinta, noventa días o siempre", async () => {
  const store = await library();
  for (const days of [7, 30, 90, null]) {
    await store.mutate("settings_save", { settings: { jobHistoryDays: days } });
    assert.equal(store.index().settings.jobHistoryDays, days);
  }
  for (const days of [15, 0, "7"]) await assert.rejects(store.mutate("settings_save", { settings: { jobHistoryDays: days } }));
});

test("guardar «siempre» sobrevive a reabrir la biblioteca", async () => {
  const root = join(dir, "library");
  let store = await library(root);
  await store.mutate("settings_save", { settings: { jobHistoryDays: null } });
  await closeLibrary(store);
  store = await library(root);
  assert.equal(historyDays(store.index().settings.jobHistoryDays), null);
  await store.mutate("settings_save", { settings: { jobHistoryDays: 90 } });
  await closeLibrary(store);
  store = await library(root);
  assert.equal(historyDays(store.index().settings.jobHistoryDays), 90);
});

test("el repaso borra solo los trabajos caducados y nunca las notas", async () => {
  const store = await library();
  const notes: string[] = [];
  for (const name of ["vieja.wav", "reciente.wav", "pendiente.wav", "activa.wav"]) notes.push(str((await imported(store, name)).id));
  const queue = await Queue.open(store);
  const publish = (note: string) => ({ recordingId: note, destinationId: "notion" });
  const old = await failedJob(queue, "publishRecording", publish(notes[0]!));
  const recent = await failedJob(queue, "publishRecording", publish(notes[1]!));
  const pending = await failedJob(queue, "publishRecording", publish(notes[2]!));
  const now = Date.now();
  const ended = (id: string, at: number) => store.withStore(async (inner) => {
    const target = (await loadOne(inner.database, id))!;
    target.finishedAt = at;
    await save(inner, target);
  });
  await ended(old, now - 8 * DAY);
  await ended(recent, now - 6 * DAY);
  await ended(pending, now - 8 * DAY);
  await store.mutate("account_effect_begin", { recordingId: notes[2] });
  const active = await queue.enqueue("publishRecording", publish(notes[3]!));
  await store.mutate("settings_save", { settings: { jobHistoryDays: null } });
  assert.equal(await queue.purge(now), 0);
  await store.mutate("settings_save", { settings: { jobHistoryDays: 7 } });
  assert.equal(await queue.purge(now), 1);
  assert.deepEqual((await history(queue)).map((item) => item.id).sort(), [recent, pending].sort());
  assert.equal(obj(queue.visible()[0]).id, active);
  assert.equal(store.index().recordings.length, 4);
  await store.recording(notes[0]!);
});

test("cada ejecución se apunta al trabajo que la lanzó", () => {
  assert.equal(obj(stampTrace("trace_save", { recordingId: "n", jobId: "inventado" }, "job-1")).jobId, "job-1");
  assert.deepEqual(stampTrace("recording_update", { id: "n" }, "job-1"), { id: "n" });
});

const iso = (millis: number) => new Date(millis).toISOString();

test("las ejecuciones antiguas se asocian por nota y hora", () => {
  const dry = job("prueba", "n", "processRecording", "failed", 300);
  dry.args = { recordingId: "n", options: { dryRun: true } };
  const jobs = [job("primero", "n", "processRecording", "succeeded", 100), job("segundo", "n", "processRecording", "failed", 200), job("publicar", "n", "publishRecording", "succeeded", 250), dry, job("otra", "m", "processRecording", "succeeded", 255)];
  const trace = (started: number, dryRun: boolean) => ({ recordingId: "n", startedAt: iso(started), dryRun });
  assert.equal(traceOwner(trace(260, false), jobs), "segundo");
  assert.equal(traceOwner(trace(150, false), jobs), "primero");
  assert.equal(traceOwner(trace(310, true), jobs), "prueba");
  assert.equal(traceOwner(trace(50, false), jobs), undefined);
  assert.equal(traceOwner({ recordingId: "n", startedAt: iso(260), jobId: "primero" }, jobs), "primero");
  assert.equal(traceOwner({ recordingId: "n", startedAt: iso(260), jobId: "borrado" }, jobs), undefined);
});

test("los pasos de un trabajo son las ejecuciones de cada intento", async () => {
  const store = await library();
  const notes = [str((await imported(store, "una.wav")).id), str((await imported(store, "otra.wav")).id)];
  const queue = await Queue.open(store);
  const id = await queue.enqueue("processRecording", { recordingId: notes[0] });
  const now = Date.now();
  const trace = (recording: string, started: number) => ({ recordingId: recording, recipeId: "default", dryRun: false, startedAt: iso(started), finishedAt: iso(started + 1000), steps: [], error: null });
  assert.ok(await queue.claim("inference"));
  await store.traceSave(stampTrace("trace_save", trace(notes[0]!, now), id));
  await queue.finish(id, failure("backend_unavailable", "429"));
  await store.withStore(async (inner) => {
    const waiting = (await loadOne(inner.database, id))!;
    waiting.nextAttemptAt = 0;
    await save(inner, waiting);
  });
  assert.ok(await queue.claim("inference"));
  await store.traceSave(stampTrace("trace_save", trace(notes[0]!, now + 5000), id));
  await queue.finish(id, ok());
  const other = await queue.enqueue("processRecording", { recordingId: notes[1] });
  await store.traceSave(stampTrace("trace_save", trace(notes[1]!, now), other));
  const steps = arr(await store.jobSteps(id));
  assert.deepEqual(steps.map((item) => item.startedAt), [iso(now + 5000), iso(now)]);
  assert.ok(steps.every((item) => item.jobId === id));
  await assert.rejects(store.jobSteps("desconocido"));
});

test("la cola no entrega un trabajo dos veces", async () => {
  const store = await library();
  const ids: string[] = [];
  for (let index = 0; index < 30; index++) ids.push(str((await imported(store, `sintetica-${index}.wav`)).id));
  const queue = await Queue.open(store);
  for (const [index, id] of ids.entries()) {
    if (index % 2 === 0) await queue.enqueue("processRecording", { recordingId: id });
    else await queue.enqueue("publishRecording", { recordingId: id, destinationId: "d" });
  }
  const expected = 45;
  const claimed = new Set<string>();
  const running = new Set<string>();
  let finishedCount = 0;
  const claimer = async (lane: "inference" | "io") => {
    while (finishedCount < expected) {
      const claimedJob = await queue.claim(lane);
      if (!claimedJob) {
        await new Promise((resolve) => setTimeout(resolve, 1));
        continue;
      }
      const id = str(obj(claimedJob).id);
      const note = str(obj(claimedJob).recordingId);
      assert.ok(!claimed.has(id), "La cola entregó dos veces el mismo trabajo");
      claimed.add(id);
      assert.ok(!running.has(note), "La cola entregó dos trabajos de la misma nota a la vez");
      running.add(note);
      await new Promise((resolve) => setImmediate(resolve));
      running.delete(note);
      assert.ok(await queue.finish(id, ok({})));
      if (obj(claimedJob).operation === "processRecording") await queue.enqueue("publishRecording", { recordingId: note, destinationId: "d" });
      finishedCount += 1;
    }
  };
  await Promise.all((["inference", "inference", "io", "io", "io", "io"] as const).map(claimer));
  assert.equal(claimed.size, expected);
}, 60000);

test("cancelar y terminar a la vez", async () => {
  const store = await library();
  const ids: string[] = [];
  for (let index = 0; index < 20; index++) ids.push(str((await imported(store, `nota-${index}.wav`)).id));
  const queue = await Queue.open(store);
  for (const note of ids) {
    const id = await queue.enqueue("processRecording", { recordingId: note });
    assert.equal(obj(await queue.claim("inference")).id, id);
    const [finishedResult, cancellation] = await Promise.all([queue.finish(id, ok({})), queue.cancel(note)]);
    const cancelled = cancellation.ids.includes(id);
    assert.notEqual(finishedResult, cancelled, "El trabajo quedó terminado y cancelado a la vez, o ninguna de las dos");
    assert.equal((await store.job(id))!.state, finishedResult ? "succeeded" : "cancelled");
  }
});
