import type { JSONObject, JSONValue, Snapshot } from "../types";
export interface RuntimeHost {
  call(method: string, params?: Record<string, unknown>): Promise<unknown>;
}
export interface WorkerTask {
  kind:
    | "recipe"
    | "recipe-schema"
    | "recipe-inspect"
    | "connector"
    | "connector-inspect";
  program?: string;
  payload: Record<string, unknown>;
}
export interface WorkerContext {
  signal?: AbortSignal;
  timeoutMs?: number;
  call(
    operation: string,
    payload: unknown,
    signal?: AbortSignal,
  ): Promise<unknown>;
}
export interface RuntimeRunner {
  run(task: WorkerTask, context: WorkerContext): Promise<unknown>;
}
export const message = (error: unknown) =>
  error instanceof Error ? error.message : String(error);
export type ErrorCode = "backend_unavailable" | "recipe_unavailable" | "runtime_unavailable" | "microphone_denied" | "failed";
export class RuntimeError extends Error {
  constructor(message: string, public readonly code: ErrorCode) { super(message); }
}
export const errorCode = (error: unknown): ErrorCode =>
  error instanceof RuntimeError ? error.code : "failed";
export function protocolError(value: Record<string, unknown>): RuntimeError {
  const message = String(value.message || "El trabajo falló");
  switch (value.code) {
    case "backend_unavailable":
    case "recipe_unavailable":
    case "runtime_unavailable":
    case "microphone_denied":
      return new RuntimeError(message, value.code);
    default:
      return new RuntimeError(message, "failed");
  }
}
export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw Error("Se esperaba un objeto");
  return value as Record<string, unknown>;
}
export function text(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw Error(`Falta ${name}`);
  return value;
}
export function json(value: unknown): JSONValue {
  const serialized = JSON.stringify(value);
  if (serialized === undefined) throw Error("El valor no es JSON");
  return JSON.parse(serialized) as JSONValue;
}
export function jsonObject(value: unknown): JSONObject {
  return object(json(value)) as JSONObject;
}
export function aborted(signal?: AbortSignal) {
  if (signal?.aborted)
    throw new DOMException("Proceso cancelado", "AbortError");
}
export async function request<T>(
  host: RuntimeHost,
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  return (await host.call(method, params)) as T;
}
export type RuntimeContext = Pick<
  Snapshot,
  "recordings" | "resolvers" | "recipes" | "accounts" | "destinations" | "providers"
> & {
  settings: Pick<
    Snapshot["settings"],
    "defaultRecipeId" | "language" | "whisperModel"
  >;
};
export const readContext = (host: RuntimeHost, recordingId?: string) =>
  request<RuntimeContext>(
    host,
    "runtime_context",
    recordingId ? { recordingId } : {},
  );
