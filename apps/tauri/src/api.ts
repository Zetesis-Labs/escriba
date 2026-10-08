import { invoke, isTauri, convertFileSrc } from "@tauri-apps/api/core";
import type { Snapshot, JSONValue } from "./types";

export const desktop = isTauri();
export async function call<T = unknown>(
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  if (!desktop)
    throw new Error(
      "Abre Escriba Tauri para usar el motor y la biblioteca locales.",
    );
  return invoke<T>("app_command", { method, params });
}
export const snapshot = () => call<Snapshot>("snapshot");
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
