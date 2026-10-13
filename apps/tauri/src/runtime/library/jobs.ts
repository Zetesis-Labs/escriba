import type { ErrorCode } from "../contracts";
import { canonical, clone, isObject, newId, text, type Json } from "./json";
import type { Store } from "./store";
import type { Persistence } from "./persistence";

export type JobState = "queued" | "running" | "retry" | "failed" | "succeeded" | "cancelled";
export type JobOperation = "processRecording" | "summarizeRecording" | "publishRecording" | "unpublishRecording";
export type Lane = "inference" | "io";
export interface RecipeRef {
  id: string;
  name: string;
}
export interface Job {
  id: string;
  recordingId: string;
  operation: JobOperation;
  args: Json;
  automatic: boolean;
  audioHash: string | null;
  recipe: RecipeRef | null;
  state: JobState;
  stage: string;
  attempt: number;
  createdAt: number;
  startedAt: number;
  finishedAt: number | null;
  nextAttemptAt: number;
  error: string | null;
  errorCode: ErrorCode | null;
  result: Json | null;
  extra: Record<string, Json>;
}
export interface JobFailure {
  code: ErrorCode;
  message: string;
}
export type JobResult = { ok: true; value: Json } | { ok: false; error: JobFailure };
export const retryable = (code: ErrorCode) => ["backend_unavailable", "recipe_unavailable", "runtime_unavailable"].includes(code);
export const LANES: Lane[] = ["inference", "io"];
export const capacity = (lane: Lane) => (lane === "inference" ? 1 : 3);
export const laneOf = (operation: JobOperation): Lane => (operation === "processRecording" || operation === "summarizeRecording" ? "inference" : "io");
const STATES: JobState[] = ["queued", "running", "retry", "failed", "succeeded", "cancelled"];
const OPERATIONS: JobOperation[] = ["processRecording", "summarizeRecording", "publishRecording", "unpublishRecording"];
const ERROR_CODES: ErrorCode[] = ["backend_unavailable", "recipe_unavailable", "runtime_unavailable", "microphone_denied", "failed"];
export const active = (job: Job) => job.state === "queued" || job.state === "running" || job.state === "retry";
const dryRun = (job: Job) => isObject(job.args) && isObject(job.args.options) && job.args.options.dryRun === true;
const endedAt = (job: Job) => job.finishedAt ?? Math.max(job.startedAt, job.createdAt);
const end = (job: Job) => {
  job.finishedAt = Date.now();
};
export function durable(operation: string): operation is JobOperation {
  return (OPERATIONS as string[]).includes(operation);
}
export function recipeFor(args: Json, note: string | null | undefined, fallback: string | null | undefined, recipes: Json): RecipeRef | null {
  const requested = [isObject(args) && isObject(args.options) ? args.options.recipeId : undefined, note, fallback].find((value) => typeof value === "string" && value) as string | undefined;
  if (!requested) return null;
  const found = Array.isArray(recipes) ? recipes.find((recipe) => isObject(recipe) && (recipe.id === requested || recipe.name === requested)) : undefined;
  const field = (key: string) => (isObject(found) && typeof found[key] === "string" ? (found[key] as string) : requested);
  return { id: field("id"), name: field("name") };
}
function recipeOf(store: Store, job: Job): RecipeRef | null {
  if (job.operation !== "processRecording") return null;
  const note = store.data.recordings.find((record) => record.id === job.recordingId)?.recipeId;
  return recipeFor(job.args, note, store.data.settings.defaultRecipeId, store.data.recipes);
}
export interface HistoryCursor {
  endedAt: number;
  id: string;
}
export interface HistoryQuery {
  before?: HistoryCursor;
  state?: JobState;
  recipeId?: string;
  operation?: JobOperation;
  limit: number;
}
export interface HistoryPage {
  jobs: Job[];
  recipes: RecipeRef[];
  next: HistoryCursor | null;
}
export function parseHistoryQuery(value: unknown): HistoryQuery {
  if (!isObject(value)) throw Error("Parámetros inválidos para runtime_history");
  const query: HistoryQuery = { limit: 0 };
  for (const [key, item] of Object.entries(value)) {
    if (key === "limit") {
      if (typeof item !== "number" || !Number.isInteger(item) || item < 0) throw Error("Parámetros inválidos para runtime_history: limit");
      query.limit = item;
    } else if (item === null || item === undefined) continue;
    else if (key === "before") {
      if (!isObject(item) || typeof item.endedAt !== "number" || typeof item.id !== "string") throw Error("Parámetros inválidos para runtime_history: before");
      query.before = { endedAt: item.endedAt, id: item.id };
    } else if (key === "state") {
      if (!(STATES as unknown[]).includes(item)) throw Error("Parámetros inválidos para runtime_history: state");
      query.state = item as JobState;
    } else if (key === "recipeId") {
      if (typeof item !== "string") throw Error("Parámetros inválidos para runtime_history: recipeId");
      query.recipeId = item;
    } else if (key === "operation") {
      if (!(OPERATIONS as unknown[]).includes(item)) throw Error("Parámetros inválidos para runtime_history: operation");
      query.operation = item as JobOperation;
    } else throw Error(`Parámetros inválidos para runtime_history: ${key}`);
  }
  if (!("limit" in value)) throw Error("Parámetros inválidos para runtime_history: limit");
  return query;
}
const compareEnded = (a: Job, b: Job) => (endedAt(b) !== endedAt(a) ? endedAt(b) - endedAt(a) : b.id < a.id ? -1 : b.id > a.id ? 1 : 0);
export function historyPage(input: Job[], query: HistoryQuery): HistoryPage {
  const jobs = input.filter((job) => !active(job)).sort(compareEnded);
  const recipes: RecipeRef[] = [];
  for (const job of jobs) if (job.recipe && !recipes.some((known) => known.id === job.recipe!.id)) recipes.push({ ...job.recipe });
  const before = query.before;
  const matching = jobs
    .filter((job) => query.state === undefined || job.state === query.state)
    .filter((job) => query.recipeId === undefined || job.recipe?.id === query.recipeId)
    .filter((job) => query.operation === undefined || job.operation === query.operation)
    .filter((job) => !before || endedAt(job) < before.endedAt || (endedAt(job) === before.endedAt && job.id < before.id))
    .slice(0, query.limit + 1);
  let next: HistoryCursor | null = null;
  if (matching.length > query.limit) {
    matching.length = query.limit;
    const last = matching.at(-1);
    if (last) next = { endedAt: endedAt(last), id: last.id };
  }
  return { jobs: matching, recipes, next };
}
export interface Cancellation {
  ids: string[];
  inference: boolean;
}
export function nextInLane(jobs: Job[], lane: Lane, now: number): number | undefined {
  const inLane = (job: Job) => laneOf(job.operation) === lane;
  const running = jobs.filter((job) => inLane(job) && job.state === "running").length;
  if (running >= capacity(lane)) return undefined;
  const busy = new Set(jobs.filter((job) => job.state === "running").map((job) => job.recordingId));
  let chosen: number | undefined;
  jobs.forEach((job, index) => {
    if (!inLane(job) || !(job.state === "queued" || job.state === "retry") || job.nextAttemptAt > now || busy.has(job.recordingId)) return;
    if (chosen === undefined) chosen = index;
    else {
      const best = jobs[chosen]!;
      if (job.createdAt < best.createdAt || (job.createdAt === best.createdAt && job.id < best.id)) chosen = index;
    }
  });
  return chosen;
}
export function parseJob(value: Json): Job {
  if (!isObject(value)) throw Error("Trabajo guardado inválido");
  const { id, recordingId, operation, args, state } = value;
  if (typeof id !== "string" || typeof recordingId !== "string" || !(OPERATIONS as unknown[]).includes(operation) || !(STATES as unknown[]).includes(state) || args === undefined)
    throw Error("Trabajo guardado inválido");
  const number = (key: string, fallback: number) => (typeof value[key] === "number" ? (value[key] as number) : fallback);
  const optional = (key: string) => (typeof value[key] === "string" ? (value[key] as string) : null);
  const recipe = value.recipe;
  const KNOWN = ["id", "recordingId", "operation", "args", "automatic", "audioHash", "recipe", "state", "stage", "attempt", "createdAt", "startedAt", "finishedAt", "nextAttemptAt", "error", "errorCode", "result"];
  const extra: Record<string, Json> = {};
  for (const [key, item] of Object.entries(value)) if (!KNOWN.includes(key)) extra[key] = item as Json;
  const job: Job = {
    id,
    recordingId,
    operation: operation as JobOperation,
    args: args as Json,
    automatic: value.automatic === true,
    audioHash: optional("audioHash"),
    recipe: isObject(recipe) && typeof recipe.id === "string" && typeof recipe.name === "string" ? { id: recipe.id, name: recipe.name } : null,
    state: state as JobState,
    stage: typeof value.stage === "string" ? value.stage : "",
    attempt: number("attempt", 0),
    createdAt: number("createdAt", 0),
    startedAt: number("startedAt", 0),
    finishedAt: typeof value.finishedAt === "number" ? value.finishedAt : null,
    nextAttemptAt: number("nextAttemptAt", 0),
    error: optional("error"),
    errorCode: (ERROR_CODES as unknown[]).includes(value.errorCode) ? (value.errorCode as ErrorCode) : null,
    result: value.result === undefined ? null : (value.result as Json),
    extra,
  };
  if (job.state === "retry" && job.errorCode === null) {
    if (job.error?.startsWith("BACKEND_UNAVAILABLE:")) job.errorCode = "backend_unavailable";
    else if (job.error?.startsWith("RECIPE_UNAVAILABLE:")) job.errorCode = "recipe_unavailable";
  }
  return job;
}
export const jobJson = (job: Job): Json => {
  const { extra, ...fields } = job;
  return clone({ ...extra, ...fields }) as unknown as Json;
};
const parseAll = (values: Json[]) => values.map(parseJob);
export const loadActive = async (database: Persistence) => parseAll(await database.jobsActive());
export const loadFor = async (database: Persistence, recording: string) => parseAll(await database.jobsFor(recording));
export async function loadOne(database: Persistence, id: string): Promise<Job | undefined> {
  const value = await database.job(id);
  return value === undefined ? undefined : parseJob(value);
}
export const save = (store: Store, job: Job) => store.jobSave(jobJson(job));
export type Claimed = { kind: "job"; job: Json } | { kind: "blocked" } | { kind: "empty" };

export async function recover(store: Store) {
  for (const job of await loadActive(store.database)) {
    if (job.state !== "running") continue;
    job.state = "queued";
    job.stage = "Recuperando trabajo interrumpido";
    job.nextAttemptAt = 0;
    await save(store, job);
  }
}
export async function enqueue(store: Store, operation: string, args: Json, automatic: boolean): Promise<[string, Lane]> {
  if (!durable(operation)) throw Error("Operación no encolable");
  const recordingId = text(args, "recordingId");
  const record = store.data.recordings.find((item) => item.id === recordingId);
  if (!record) throw Error("Grabación no encontrada");
  if (record.status === "discarded") throw Error("Restaura la grabación antes de procesarla");
  const existing = (await loadFor(store.database, recordingId)).find(active);
  if (existing) {
    if (existing.operation === operation && canonical(existing.args) === canonical(args)) return [existing.id, laneOf(operation)];
    throw Error("La grabación ya tiene un trabajo pendiente");
  }
  const time = Date.now();
  const job: Job = {
    id: newId(),
    recordingId,
    operation,
    args,
    automatic,
    audioHash: record.audioHash ?? null,
    recipe: null,
    state: "queued",
    stage: "En cola",
    attempt: 0,
    createdAt: time,
    startedAt: time,
    finishedAt: null,
    nextAttemptAt: 0,
    error: null,
    errorCode: null,
    result: null,
    extra: {},
  };
  job.recipe = recipeOf(store, job);
  await save(store, job);
  return [job.id, laneOf(operation)];
}
export async function automatic(store: Store): Promise<boolean> {
  const pending = store.data.recordings.filter((record) => record.status === "pending" && typeof record.audioPath === "string").map((record) => [record.id, record.audioHash ?? null] as const);
  let enqueued = false;
  for (const [id, audioHash] of pending) {
    const handled = (await loadFor(store.database, id)).some((job) => job.operation === "processRecording" && !dryRun(job) && (active(job) || job.audioHash === audioHash));
    if (!handled) {
      await enqueue(store, "processRecording", { recordingId: id, options: { force: false } }, true);
      enqueued = true;
    }
  }
  return enqueued;
}
export async function claim(store: Store, lane: Lane, now: number): Promise<Claimed> {
  const jobs = await loadActive(store.database);
  const index = nextInLane(jobs, lane, now);
  if (index === undefined) return { kind: "empty" };
  const job = jobs[index]!;
  const force = isObject(job.args) && isObject(job.args.options) ? job.args.options.force : undefined;
  if (job.operation === "processRecording" && (job.automatic || job.attempt > 0 || force === false) && (await store.recording(job.recordingId)).accountEffectPending === true) {
    const message = "Revisa la operación externa antes de reprocesar esta nota manualmente";
    job.state = "failed";
    job.stage = "Error";
    job.error = message;
    job.errorCode = "failed";
    end(job);
    await store.mutate("recording_update", { id: job.recordingId, status: "failed", error: message });
    await save(store, job);
    return { kind: "blocked" };
  }
  job.attempt += 1;
  if (job.attempt > 1 && job.operation === "processRecording") {
    if (!isObject(job.args)) job.args = {};
    const args = job.args as Record<string, Json>;
    if (!isObject(args.options)) args.options = {};
    (args.options as Record<string, Json>).force = false;
  }
  job.state = "running";
  job.stage = "Procesando";
  job.startedAt = now;
  job.recipe = recipeOf(store, job);
  await save(store, job);
  return { kind: "job", job: jobJson(job) };
}
export async function finish(store: Store, id: string, result: JobResult): Promise<Lane | undefined> {
  const job = await loadOne(store.database, id);
  if (!job || job.state === "cancelled") return undefined;
  if (result.ok) {
    job.state = "succeeded";
    job.result = result.value;
    job.stage = "Completado";
    job.error = null;
    job.errorCode = null;
    end(job);
  } else {
    const retry = retryable(result.error.code);
    job.state = retry ? "retry" : "failed";
    job.stage = retry ? "Esperando al servicio" : "Error";
    job.error = result.error.message;
    job.errorCode = result.error.code;
    if (retry) {
      const seconds = Math.min(10 * 2 ** Math.min(job.attempt, 5), 300);
      job.nextAttemptAt = Date.now() + seconds * 1000;
    } else end(job);
    if (job.operation === "processRecording" && !dryRun(job))
      await store.mutate("recording_update", { id: job.recordingId, status: retry ? "pending" : "failed", error: result.error.message });
  }
  await save(store, job);
  return laneOf(job.operation);
}
export async function stages(store: Store, value: Json) {
  if (!Array.isArray(value)) throw Error("Estado de trabajos inválido");
  for (const job of (await loadActive(store.database)).filter((job) => job.state === "running")) {
    const stage = value.find((item) => isObject(item) && item.recordingId === job.recordingId);
    if (!stage) continue;
    const name = text(stage, "stage");
    if (job.stage !== name) {
      job.stage = name;
      await save(store, job);
    }
  }
}
export async function cancel(store: Store, recording: string): Promise<Cancellation> {
  const cancellation: Cancellation = { ids: [], inference: false };
  for (const job of (await loadFor(store.database, recording)).filter(active)) {
    cancellation.ids.push(job.id);
    cancellation.inference ||= job.state === "running" && laneOf(job.operation) === "inference";
    job.state = "cancelled";
    job.error = "Proceso cancelado";
    job.errorCode = "failed";
    job.stage = "Cancelado";
    end(job);
    await save(store, job);
    if (job.operation === "processRecording" && !dryRun(job)) await store.mutate("recording_update", { id: recording, status: "failed", error: "Proceso cancelado" });
  }
  return cancellation;
}
export function historyDays(setting: number | null | undefined): number | null {
  if (setting === undefined) return 7;
  return setting;
}
export function expired(jobs: Job[], cutoff: number, pending: Set<string>): string[] {
  return jobs.filter((job) => !active(job) && endedAt(job) < cutoff && !pending.has(job.recordingId)).map((job) => job.id);
}
export async function purge(store: Store, now: number): Promise<number> {
  const days = historyDays(store.data.settings.jobHistoryDays);
  if (days === null) return 0;
  const pending = new Set(store.data.recordings.filter((record) => (record as Record<string, unknown>).accountEffectPending === true).map((record) => record.id));
  const jobs = parseAll(await store.database.jobsFinished());
  const gone = expired(jobs, now - days * 86_400_000, pending);
  if (gone.length) await store.database.removeJobs(gone);
  return gone.length;
}
export function stampTrace(method: string, params: Json, task: string): Json {
  if (method === "trace_save" && isObject(params)) return { ...params, jobId: task };
  return params;
}
export function traceOwner(trace: Json, jobs: Job[]): string | undefined {
  if (!isObject(trace)) return undefined;
  if (typeof trace.jobId === "string") return jobs.some((job) => job.id === trace.jobId) ? trace.jobId : undefined;
  const recording = trace.recordingId;
  if (typeof recording !== "string" || typeof trace.startedAt !== "string") return undefined;
  const started = Date.parse(trace.startedAt);
  if (Number.isNaN(started)) return undefined;
  const isDryRun = trace.dryRun === true;
  let owner: Job | undefined;
  for (const job of jobs) {
    if (job.operation !== "processRecording" || job.recordingId !== recording || dryRun(job) !== isDryRun || job.createdAt > started) continue;
    if (!owner || job.createdAt > owner.createdAt || (job.createdAt === owner.createdAt && job.id > owner.id)) owner = job;
  }
  return owner?.id;
}
export async function steps(database: Persistence, id: string): Promise<Json[]> {
  const job = await loadOne(database, id);
  if (!job) throw Error("Trabajo desconocido");
  const jobs = await loadFor(database, job.recordingId);
  return (await database.traceList(job.recordingId)).filter((trace) => traceOwner(trace, jobs) === id);
}
export function relaunchArgs(job: Job): Json {
  if (job.operation === "processRecording" && !dryRun(job)) return { recordingId: job.recordingId, options: { force: true } };
  return clone(job.args);
}
export async function relaunch(store: Store, id: string): Promise<[string, Lane]> {
  const job = await loadOne(store.database, id);
  if (!job) throw Error("Trabajo desconocido");
  if (job.state !== "failed" && job.state !== "cancelled") throw Error("Solo se pueden volver a lanzar trabajos fallidos o cancelados");
  if ((await store.recording(job.recordingId)).accountEffectPending === true) throw Error("Revisa la operación externa de esta nota antes de volver a lanzar el trabajo");
  return enqueue(store, job.operation, relaunchArgs(job), false);
}
export async function busy(database: Persistence, recording: string): Promise<boolean> {
  return (await loadFor(database, recording)).some(active);
}
export async function visible(database: Persistence): Promise<Json[]> {
  return (await loadActive(database)).sort((a, b) => a.createdAt - b.createdAt).map(jobJson);
}
export async function history(database: Persistence, query: HistoryQuery): Promise<HistoryPage> {
  return historyPage(parseAll(await database.jobsFinished()), query);
}
export const find = (database: Persistence, id: string) => loadOne(database, id);
