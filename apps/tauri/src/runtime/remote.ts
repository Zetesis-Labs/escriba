import { openAsBlob } from "node:fs";
import { basename } from "node:path";
import { RuntimeError, object, text } from "./contracts";
import type { HttpTransport } from "./http";

const RESPONSE_LIMIT = 32 * 1024 * 1024;
const REMOTE_TIMEOUT_MS = 1_800_000;

export function privateHost(raw: string): boolean {
  const host = raw.replace(/^\[|\]$/g, "").toLowerCase();
  if (host === "localhost" || host.endsWith(".local") || host === "::1") return true;
  if (host.startsWith("fc") || host.startsWith("fd")) return host.includes(":");
  const parts = host.split(".");
  if (parts.length !== 4) return false;
  const octets = parts.map((part) => (/^\d+$/.test(part) ? Number(part) : NaN));
  if (octets.some((octet) => !Number.isInteger(octet) || octet > 255)) return false;
  const [a, b] = octets as [number, number, number, number];
  return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) || (a === 100 && b >= 64 && b <= 127);
}
export function endpoint(resolver: Record<string, unknown>, route: string): URL {
  const base = text(resolver.url, "url");
  let url: URL;
  try {
    url = new URL(base);
  } catch {
    throw Error("URL del resolutor inválida");
  }
  if (url.username || url.password) throw Error("La URL no puede llevar usuario ni contraseña");
  if (!(url.protocol === "https:" || (url.protocol === "http:" && privateHost(url.hostname))))
    throw Error("Usa https:// para un servicio fuera de tu red");
  url.pathname = `${url.pathname.replace(/\/+$/, "")}/${route}`;
  url.search = "";
  url.hash = "";
  return url;
}
export function silentWav(): Uint8Array<ArrayBuffer> {
  const rate = 16_000;
  const data = rate * 2;
  const wav = new Uint8Array(new ArrayBuffer(44 + data));
  const view = new DataView(wav.buffer);
  const ascii = (offset: number, value: string) => {
    for (let index = 0; index < value.length; index++) wav[offset + index] = value.charCodeAt(index);
  };
  ascii(0, "RIFF");
  view.setUint32(4, 36 + data, true);
  ascii(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, data, true);
  return wav;
}
async function send(transport: HttpTransport, request: Request, secret: string | undefined, unavailable: string) {
  let response: Response;
  try {
    response = await transport(request);
  } catch {
    throw new RuntimeError(unavailable, "backend_unavailable");
  }
  return readResponse(response, secret);
}
export async function readResponse(response: Response, secret: string | undefined): Promise<unknown> {
  const chunks: Uint8Array[] = [];
  let received = 0;
  if (response.body) {
    const reader = response.body.getReader();
    for (;;) {
      let next: ReadableStreamReadResult<Uint8Array>;
      try {
        next = await reader.read();
      } catch {
        throw new RuntimeError("Se cortó la respuesta del resolutor", "backend_unavailable");
      }
      if (next.done) break;
      received += next.value.length;
      if (received > RESPONSE_LIMIT) throw Error("Respuesta del resolutor demasiado grande");
      chunks.push(next.value);
    }
  }
  const bytes = new Uint8Array(received);
  let position = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, position);
    position += chunk.length;
  }
  let body = new TextDecoder().decode(bytes);
  if (secret) body = body.split(secret).join("[credencial]");
  if (!response.ok) {
    const status = response.status;
    const unavailable = status >= 500 || [401, 403, 408, 429].includes(status);
    throw new RuntimeError(
      `El resolutor respondió ${status}${response.statusText ? ` ${response.statusText}` : ""}: ${[...body].slice(0, 1000).join("")}`,
      unavailable ? "backend_unavailable" : "failed",
    );
  }
  try {
    return JSON.parse(body);
  } catch {
    throw Error("Respuesta JSON inválida del resolutor");
  }
}
function request(url: URL, secret: string | undefined, init: RequestInit) {
  const headers = new Headers(init.headers);
  if (secret) headers.set("authorization", `Bearer ${secret}`);
  return new Request(url, { ...init, headers, redirect: "manual", signal: AbortSignal.timeout(REMOTE_TIMEOUT_MS) });
}
export async function models(resolver: Record<string, unknown>, secret: string | undefined, transport: HttpTransport = fetch): Promise<string[]> {
  const value = object(await send(transport, request(endpoint(resolver, "models"), secret, { method: "GET" }), secret, "No se pudo conectar con el servicio"));
  const ids = (Array.isArray(value.data) ? value.data : [])
    .map((model) => (model && typeof model === "object" ? (model as { id?: unknown }).id : undefined))
    .filter((id): id is string => typeof id === "string");
  return [...new Set(ids)].sort();
}
export async function probeTranscription(resolver: Record<string, unknown>, secret: string | undefined, transport: HttpTransport = fetch): Promise<string> {
  const form = new FormData();
  form.append("file", new File([silentWav()], "prueba.wav", { type: "audio/wav" }));
  form.append("model", text(resolver.model, "model"));
  form.append("response_format", "json");
  const value = object(await send(transport, request(endpoint(resolver, "audio/transcriptions"), secret, { method: "POST", body: form }), secret, "No se pudo conectar con el servicio"));
  return typeof value.text === "string" ? value.text.trim() : "";
}
export async function transcribe(
  resolver: Record<string, unknown>,
  secret: string | undefined,
  path: string,
  params: Record<string, unknown>,
  transport: HttpTransport = fetch,
): Promise<Record<string, unknown>> {
  if (params.diarize === true) throw Error("La detección de hablantes requiere Whisper local");
  let blob: Blob;
  try {
    blob = await openAsBlob(path);
  } catch {
    throw Error("No se pudo leer el audio de la grabación");
  }
  const form = new FormData();
  form.append("file", new File([blob], basename(path)));
  form.append("model", text(resolver.model, "model"));
  form.append("response_format", "verbose_json");
  if (typeof params.language === "string" && params.language) form.append("language", params.language);
  const value = object(await send(transport, request(endpoint(resolver, "audio/transcriptions"), secret, { method: "POST", body: form }), secret, "No se pudo conectar con el resolutor STT"));
  if (typeof value.text !== "string") throw Error("La respuesta no contiene transcripción");
  if (!value.text.trim()) throw Error("El resolutor devolvió una transcripción vacía");
  return {
    text: value.text,
    segments: Array.isArray(value.segments) ? value.segments : [],
    language: typeof value.language === "string" ? value.language : "",
    duration: typeof value.duration === "number" ? value.duration : 0,
  };
}
export async function ask(
  resolver: Record<string, unknown>,
  secret: string | undefined,
  params: Record<string, unknown>,
  transport: HttpTransport = fetch,
): Promise<unknown> {
  const body: Record<string, unknown> = {
    model: text(resolver.model, "model"),
    messages: [
      { role: "system", content: text(params.instructions, "instructions") },
      { role: "user", content: text(params.prompt, "prompt") },
    ],
    temperature: 0.2,
  };
  const schema = params.schema !== undefined && params.schema !== null ? params.schema : undefined;
  if (schema !== undefined)
    body.response_format = { type: "json_schema", json_schema: { name: "escriba", strict: true, schema } };
  const value = object(await send(transport, request(endpoint(resolver, "chat/completions"), secret, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }), secret, "No se pudo conectar con el resolutor LLM"));
  const choices = Array.isArray(value.choices) ? value.choices : [];
  const first = choices[0] && typeof choices[0] === "object" ? (choices[0] as { message?: { content?: unknown } }) : undefined;
  const content = first?.message?.content;
  if (typeof content !== "string" || !content.trim()) throw Error("El resolutor no devolvió contenido");
  if (schema === undefined) return content;
  try {
    return JSON.parse(content);
  } catch {
    throw Error("El resolutor no respetó el esquema JSON");
  }
}
export const digestSchema = () => ({
  type: "object",
  properties: { title: { type: "string" }, summary: { type: "string" }, tags: { type: "array", items: { type: "string" } } },
  required: ["title", "summary", "tags"],
  additionalProperties: false,
});
