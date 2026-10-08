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
export const readSnapshot = (host: RuntimeHost) =>
  request<Snapshot>(host, "snapshot");
