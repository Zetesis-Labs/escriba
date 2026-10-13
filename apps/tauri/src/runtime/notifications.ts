import { object, text } from "./contracts";
import type { JobResult } from "./library/jobs";
import { isObject, type Json } from "./library/json";

export interface Notification {
  title: string;
  body: string;
  sound: boolean;
}
export type Problem =
  | { kind: "failed"; key: string; reason: string }
  | { kind: "backendUnavailable"; reason: string }
  | { kind: "recipeUnavailable"; reason: string }
  | { kind: "transcriberUnavailable"; name: string; reason: string }
  | { kind: "summarizerUnavailable"; name: string; reason: string };

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const graphemes = (value: string) => [...segmenter.segment(value)].map((segment) => segment.segment);
const limitBody = (body: string) => graphemes(body).slice(0, 240).join("");

export function transcribed(key: string, value: string, enabled: boolean): Notification | undefined {
  if (!enabled) return undefined;
  const preview = value.replace(/\n/g, " ").trim();
  let body = key;
  if (preview) {
    const parts = graphemes(preview);
    body = parts.slice(0, 80).join("") + (parts.length > 80 ? "…" : "");
  }
  return { title: "Nota transcrita", body: limitBody(body), sound: false };
}
function titleAndBody(problem: Problem): [string, string] {
  switch (problem.kind) {
    case "failed":
      return [`Fallo al transcribir ${problem.key}`, problem.reason];
    case "backendUnavailable":
      return ["El motor de transcripción no responde", problem.reason];
    case "recipeUnavailable":
      return ["La receta por defecto no está disponible", problem.reason];
    case "transcriberUnavailable":
      return [`No se puede transcribir con ${problem.name}`, problem.reason];
    case "summarizerUnavailable":
      return [`No se puede resumir con ${problem.name}`, `${problem.reason}. Las notas se transcribirán igual.`];
  }
}
export function notification(problem: Problem): Notification {
  const [title, body] = titleAndBody(problem);
  return { title, body: limitBody(body), sound: true };
}
export function settingsChanged(method: string, params: Record<string, unknown>): boolean {
  switch (method) {
    case "config_save":
    case "config_remove":
      return params.collection === "resolvers";
    case "connector_save":
    case "connector_remove":
      return true;
    case "settings_save":
      return isObject(params.settings) && params.settings.watchedFolders !== undefined;
    default:
      return false;
  }
}
export function finished(job: Json, recording: Json, result: JobResult, settings: Json): Notification | undefined {
  if (!isObject(job) || job.operation !== "processRecording" || job.automatic !== true) return undefined;
  if (isObject(job.args) && isObject(job.args.options) && job.args.options.dryRun === true) return undefined;
  if (!result.ok && result.error.message === "Proceso cancelado") return undefined;
  const key = typeof job.recordingId === "string" ? job.recordingId : "";
  if (!result.ok) {
    const { code, message } = result.error;
    if (code === "backend_unavailable") return notification({ kind: "backendUnavailable", reason: message });
    if (code === "recipe_unavailable") return notification({ kind: "recipeUnavailable", reason: message });
    return notification({ kind: "failed", key, reason: message });
  }
  const versionId = isObject(result.value) ? result.value.versionId : undefined;
  if (typeof versionId !== "string") return undefined;
  const versions = isObject(recording) && Array.isArray(recording.versions) ? recording.versions : [];
  const version = versions.find((entry) => isObject(entry) && entry.id === versionId);
  if (!isObject(version)) return undefined;
  const transcript = isObject(version.transcript) ? version.transcript : undefined;
  const value = transcript && typeof transcript.text === "string" ? transcript.text : "";
  return transcribed(key, value, !(isObject(settings) && settings.notifyEveryNote === false));
}
export function resolverProblem(value: unknown): Notification {
  const problem = object(value);
  const name = text(problem.name, "nombre del resolutor");
  const reason = text(problem.reason, "motivo");
  if (problem.role === "stt") return notification({ kind: "transcriberUnavailable", name, reason });
  if (problem.role === "llm") return notification({ kind: "summarizerUnavailable", name, reason });
  throw Error("Rol de resolutor desconocido");
}
