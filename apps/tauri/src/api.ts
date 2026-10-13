import { invoke, isTauri, convertFileSrc } from "@tauri-apps/api/core";
import type { AppCommand } from "./generated/AppCommand";
import type { KnowledgeCommand } from "./generated/KnowledgeCommand";
import type { KnowledgeReply } from "./generated/KnowledgeReply";
import type { JSONValue, Recording, Snapshot } from "./types";
import type { ControllerMethod } from "./runtime/controllerMethods";

export type AppMethod = AppCommand["method"] | ControllerMethod;
export type KnowledgeMethod = KnowledgeCommand["method"];
export type KnowledgeParams<M extends KnowledgeMethod> = Extract<KnowledgeCommand, { method: M }>["params"];
export type KnowledgeResult<M extends KnowledgeMethod> = Extract<KnowledgeReply, { method: M }>["value"];
export type KnowledgeHost = <M extends KnowledgeMethod>(
  method: M,
  ...params: {} extends KnowledgeParams<M> ? [KnowledgeParams<M>?] : [KnowledgeParams<M>]
) => Promise<KnowledgeResult<M>>;

async function command<T>(method: AppMethod | KnowledgeMethod, params: object): Promise<T> {
  if (!isTauri())
    throw new Error(
      "Abre Escriba para usar el motor y la biblioteca locales.",
    );
  return invoke<T>("app_command", { method, params });
}

export const call = <T = unknown>(method: AppMethod, params: Record<string, unknown> = {}) =>
  command<T>(method, params);
export const knowledge: KnowledgeHost = (method, ...params) => command(method, params[0] ?? {});
export const snapshot = () => call<Snapshot>("snapshot");
export const library = () => call<Snapshot>("library");
export const recordingDetail = (id: string) => call<Recording>("recording_detail", { id });
export const audioURL = (path: string) => convertFileSrc(path);
export async function log(
  message: string,
  level = "info",
  recordingId?: string,
): Promise<void> {
  await call("log", { message, level, recordingId });
}
export const native = <T = JSONValue>(
  method: string,
  params: Record<string, unknown> = {},
) => call<T>("native", { method, params });
