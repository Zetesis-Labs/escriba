import type { HistoryCursor } from "../generated/HistoryCursor";
import type { HistoryPage } from "../generated/HistoryPage";
import type { HistoryQuery } from "../generated/HistoryQuery";
import type { Job } from "../generated/Job";
import type { JobOperation } from "../generated/JobOperation";
import type { RecipeRef } from "../generated/RecipeRef";
import { recordingWhen } from "./presentation";

export const historyPageSize = 100;

export type HistoryState = "all" | "succeeded" | "failed" | "cancelled";

export const historyStates: { value: HistoryState; label: string }[] = [
  { value: "all", label: "Todos" },
  { value: "succeeded", label: "Terminados" },
  { value: "failed", label: "Fallidos" },
  { value: "cancelled", label: "Cancelados" },
];

const manualActions: { operation: JobOperation; label: string }[] = [
  { operation: "summarizeRecording", label: "Resumir a mano" },
  { operation: "publishRecording", label: "Publicar" },
  { operation: "unpublishRecording", label: "Retirar publicación" },
];

const activeRank: Partial<Record<Job["state"], number>> = { running: 0, queued: 1, retry: 2 };

const activeTime = (job: Job) => (job.state === "running" ? job.startedAt : job.state === "retry" ? job.nextAttemptAt : job.createdAt);

export function activeOrder(jobs: Job[]): Job[] {
  return [...jobs].sort((a, b) => (activeRank[a.state] ?? 3) - (activeRank[b.state] ?? 3) || activeTime(a) - activeTime(b));
}

export function runningCount(jobs: Job[]) {
  return jobs.filter((job) => job.state === "running").length;
}

function destinationName(job: Job, destinations: { id: string; name: string }[]) {
  const args = job.args as { destinationId?: unknown } | null;
  return destinations.find((destination) => destination.id === args?.destinationId)?.name ?? "un destino borrado";
}

export function jobKind(job: Job, destinations: { id: string; name: string }[]) {
  if (job.operation === "summarizeRecording") return "Resumir a mano";
  if (job.operation === "publishRecording") return `Publicar en ${destinationName(job, destinations)}`;
  if (job.operation === "unpublishRecording") return `Retirar de ${destinationName(job, destinations)}`;
  const dryRun = (job.args as { options?: { dryRun?: unknown } } | null)?.options?.dryRun === true;
  if (dryRun) return job.recipe ? `Prueba de la receta ${job.recipe.name}` : "Prueba de receta";
  return job.recipe ? `Receta ${job.recipe.name}` : "Procesar";
}

const finalStatus: Partial<Record<Job["state"], string>> = { succeeded: "Terminado", failed: "Fallido", cancelled: "Cancelado" };

export function jobStatus(job: Job, now: Date, timeZone?: string) {
  if (job.state === "running") return job.stage || "Procesando";
  if (job.state === "queued") return "En cola";
  if (job.state === "retry") return `Reintento ${recordingWhen(new Date(job.nextAttemptAt), now, timeZone)}`;
  return finalStatus[job.state] ?? job.state;
}

function duration(milliseconds: number) {
  const seconds = Math.max(0, Math.round(milliseconds / 1000));
  if (seconds < 60) return `${seconds} s`;
  const minutes = Math.floor(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

export function jobTimes(job: Job, now: Date, timeZone?: string) {
  const when = (time: number) => recordingWhen(new Date(time), now, timeZone);
  if (job.state === "running") return `desde ${when(job.startedAt)} · ${duration(now.getTime() - job.startedAt)}`;
  if (job.state === "queued") return `desde ${when(job.createdAt)}`;
  if (job.state === "retry") return "";
  const ended = job.finishedAt ?? Math.max(job.startedAt, job.createdAt);
  return job.attempt > 0 && job.finishedAt !== null ? `${when(ended)} · ${duration(job.finishedAt - job.startedAt)}` : when(ended);
}

export function jobActions(job: Job) {
  return {
    cancel: job.state in activeRank,
    relaunch: job.state === "failed" || job.state === "cancelled",
    error: job.state === "failed" && Boolean(job.error),
  };
}

export function historyKinds(recipes: RecipeRef[]) {
  return [
    { value: "all", label: "Todas" },
    ...[...recipes].sort((a, b) => a.name.localeCompare(b.name, "es")).map((recipe) => ({ value: `recipe:${recipe.id}`, label: `Receta ${recipe.name}` })),
    ...manualActions.map((action) => ({ value: `operation:${action.operation}`, label: action.label })),
  ];
}

export function historyQuery(state: HistoryState, kind: string, before: HistoryCursor | null): HistoryQuery {
  const query: HistoryQuery = { limit: historyPageSize };
  if (state !== "all") query.state = state;
  if (kind.startsWith("recipe:")) query.recipeId = kind.slice("recipe:".length);
  const operation = manualActions.find((action) => kind === `operation:${action.operation}`)?.operation;
  if (operation) query.operation = operation;
  if (before) query.before = before;
  return query;
}

export function appendPage(rows: Job[], page: Job[]) {
  const known = new Set(rows.map((job) => job.id));
  return [...rows, ...page.filter((job) => !known.has(job.id))];
}

const endedAt = (job: Job) => job.finishedAt ?? Math.max(job.startedAt, job.createdAt);

const olderThan = (job: Job, cursor: HistoryCursor) => endedAt(job) < cursor.endedAt || (endedAt(job) === cursor.endedAt && job.id < cursor.id);

export function refreshedHistory(rows: Job[], next: HistoryCursor | null, fresh: HistoryPage) {
  if (!fresh.next) return { rows: fresh.jobs, next: null };
  const boundary = fresh.next;
  const older = rows.filter((job) => olderThan(job, boundary));
  return { rows: [...fresh.jobs, ...older], next: older.length ? next : boundary };
}
