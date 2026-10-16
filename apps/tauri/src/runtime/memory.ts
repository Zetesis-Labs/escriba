import { object, type RuntimeHost, aborted } from "./contracts";
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value)
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([key, value]) => [key, canonical(value)]),
    );
  return value;
}
export async function remember<T>(
  host: RuntimeHost,
  recordingId: string,
  enabled: boolean,
  key: unknown,
  compute: () => Promise<T>,
  signal?: AbortSignal,
  renewed?: Set<string>,
): Promise<T> {
  if (!enabled) return compute();
  const bytes = new TextEncoder().encode(JSON.stringify(canonical(key)));
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  const fingerprint = Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const params = { recordingId, fingerprint };
  if (!renewed || renewed.has(fingerprint)) {
    const cached = await host.call("memory_recall", params);
    aborted(signal);
    if (cached !== null && cached !== undefined) return object(cached).value as T;
  }
  const value = await compute();
  aborted(signal);
  await host.call("memory_keep", { ...params, value: { value } });
  renewed?.add(fingerprint);
  return value;
}
export function summaryMemory(
  host: RuntimeHost,
  recordingId: string,
  enabled: boolean,
  scope: unknown,
  signal?: AbortSignal,
  renewed?: Set<string>,
): RuntimeHost {
  return {
    call(method, params = {}) {
      return method === "summarize"
        ? remember(
            host,
            recordingId,
            enabled,
            { kind: "summary", scope, params },
            async () => {
              const value = await host.call(method, params);
              const result = object(value);
              if (
                !(typeof result.title === "string" && result.title.trim()) &&
                !(typeof result.summary === "string" && result.summary.trim())
              )
                throw Error("El modelo devolvió un resumen vacío");
              return value;
            },
            signal,
            renewed,
          )
        : host.call(method, params);
    },
  };
}
