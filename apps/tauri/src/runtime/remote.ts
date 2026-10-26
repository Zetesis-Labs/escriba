import { openAsBlob } from "node:fs";
import { basename } from "node:path";
import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createMistral } from "@ai-sdk/mistral";
import { createOpenAICompatible } from "@ai-sdk/openai-compatible";
import { APICallError, NoObjectGeneratedError, Output, generateText, jsonSchema } from "ai";
import { z } from "zod";
import { llmProvider, type LlmProvider } from "../core/resolvers";
import { answerJson } from "../core/structuredAnswer";
import { RuntimeError, object, text } from "./contracts";
import type { HttpTransport } from "./http";

const RESPONSE_LIMIT = 32 * 1024 * 1024;
// Native providers warn about settings they ignore; that is expected here, not news.
(globalThis as { AI_SDK_LOG_WARNINGS?: boolean }).AI_SDK_LOG_WARNINGS = false;
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
export function baseURL(resolver: Record<string, unknown>): string {
  return endpoint(resolver, "").href.replace(/\/$/, "");
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
function authorization(provider: LlmProvider, secret: string | undefined): Record<string, string> {
  if (!secret) return {};
  if (provider === "anthropic") return { "x-api-key": secret, "anthropic-version": "2023-06-01" };
  if (provider === "google") return { "x-goog-api-key": secret };
  return { authorization: `Bearer ${secret}` };
}
function request(url: URL, secret: string | undefined, init: RequestInit, provider: LlmProvider = "openai-compatible") {
  const headers = new Headers(init.headers);
  for (const [name, value] of Object.entries(authorization(provider, secret))) headers.set(name, value);
  return new Request(url, { ...init, headers, redirect: "manual", signal: AbortSignal.timeout(REMOTE_TIMEOUT_MS) });
}
const field = (item: unknown, name: string) => (item && typeof item === "object" ? (item as Record<string, unknown>)[name] : undefined);
export async function models(resolver: Record<string, unknown>, secret: string | undefined, transport: HttpTransport = fetch): Promise<string[]> {
  const provider = llmProvider(resolver);
  const url = endpoint(resolver, "models");
  if (provider === "anthropic") url.searchParams.set("limit", "1000");
  if (provider === "google") url.searchParams.set("pageSize", "1000");
  const value = object(await send(transport, request(url, secret, { method: "GET" }, provider), secret, "No se pudo conectar con el servicio"));
  const ids =
    provider === "google"
      ? (Array.isArray(value.models) ? value.models : [])
          .filter((model) => {
            const methods = field(model, "supportedGenerationMethods");
            return Array.isArray(methods) && methods.includes("generateContent");
          })
          .map((model) => field(model, "name"))
          .filter((name): name is string => typeof name === "string")
          .map((name) => name.replace(/^models\//, ""))
      : (Array.isArray(value.data) ? value.data : []).map((model) => field(model, "id")).filter((id): id is string => typeof id === "string");
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
const TOO_LARGE = "Respuesta del resolutor demasiado grande";
const masked = (message: string, secret: string | undefined) => (secret ? message.split(secret).join("[credencial]") : message);
function limited(response: Response): Response {
  if (!response.body) return response;
  let received = 0;
  const body = response.body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        received += chunk.length;
        if (received > RESPONSE_LIMIT) controller.error(Error(TOO_LARGE));
        else controller.enqueue(chunk);
      },
    }),
  );
  return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
}
// The SDK calls fetch(input, init); Escriba's transport gets a Request with its own limits.
function sdkFetch(transport: HttpTransport): typeof fetch {
  const call = async (input: RequestInfo | URL, init?: RequestInit) => {
    const timeout = AbortSignal.timeout(REMOTE_TIMEOUT_MS);
    const signal = init?.signal ? AbortSignal.any([init.signal, timeout]) : timeout;
    return limited(await transport(new Request(input, { ...init, redirect: "manual", signal })));
  };
  return call as typeof fetch;
}
function inferenceError(error: unknown, secret: string | undefined): Error {
  if (error instanceof RuntimeError) return new RuntimeError(masked(error.message, secret), error.code);
  if (APICallError.isInstance(error)) {
    const status = error.statusCode;
    if (status === undefined) return new RuntimeError("No se pudo conectar con el resolutor LLM", "backend_unavailable");
    if (status >= 200 && status < 300) {
      const cause = error.cause instanceof Error ? error.cause.message : "";
      if (cause === TOO_LARGE) return Error(TOO_LARGE);
      return error.cause instanceof TypeError
        ? new RuntimeError("Se cortó la respuesta del resolutor", "backend_unavailable")
        : Error("Respuesta JSON inválida del resolutor");
    }
    const body = [...masked(error.responseBody ?? "", secret)].slice(0, 1000).join("");
    return new RuntimeError(
      `El resolutor respondió ${status}: ${body}`,
      status >= 500 || [401, 403, 408, 429].includes(status) ? "backend_unavailable" : "failed",
    );
  }
  if (error instanceof Error && ["AbortError", "TimeoutError"].includes(error.name))
    return new RuntimeError("El resolutor LLM no respondió a tiempo", "backend_unavailable");
  if (error instanceof TypeError) return new RuntimeError("No se pudo conectar con el resolutor LLM", "backend_unavailable");
  return Error(masked(error instanceof Error ? error.message : String(error), secret));
}
function conforming(value: unknown, schema: unknown): unknown {
  if (value === undefined) throw Error("El resolutor no respetó el esquema JSON: la respuesta no contiene JSON");
  let validator: z.ZodType;
  try {
    validator = z.fromJSONSchema(schema as Parameters<typeof z.fromJSONSchema>[0]);
  } catch {
    // Zod can't rebuild every JSON Schema; the recipe still validates with its own.
    return value;
  }
  const result = validator.safeParse(value);
  if (result.success) return value;
  const problems = result.error.issues.map((issue) => `${issue.path.join(".") || "respuesta"}: ${issue.message}`);
  throw Error(`El resolutor no respetó el esquema JSON (${problems.join("; ")})`);
}
// Every provider gets the key explicitly: none may fall back to an environment variable.
function languageModel(resolver: Record<string, unknown>, secret: string | undefined, transport: HttpTransport) {
  const provider = llmProvider(resolver);
  const model = text(resolver.model, "model");
  const settings = { baseURL: baseURL(resolver), fetch: sdkFetch(transport) };
  if (provider === "openai-compatible")
    return createOpenAICompatible({ ...settings, name: "escriba", ...(secret ? { apiKey: secret } : {}), supportsStructuredOutputs: true })(model);
  if (!secret) throw Error("Falta la clave del resolutor");
  if (provider === "anthropic") return createAnthropic({ ...settings, apiKey: secret })(model);
  if (provider === "google") return createGoogleGenerativeAI({ ...settings, apiKey: secret })(model);
  return createMistral({ ...settings, apiKey: secret })(model);
}
export async function ask(
  resolver: Record<string, unknown>,
  secret: string | undefined,
  params: Record<string, unknown>,
  transport: HttpTransport = fetch,
): Promise<unknown> {
  const instructions = text(params.instructions, "instructions");
  const schema = params.schema !== undefined && params.schema !== null ? params.schema : undefined;
  const call = {
    model: languageModel(resolver, secret, transport),
    prompt: text(params.prompt, "prompt"),
    temperature: 0.2,
    maxRetries: 0,
  };
  try {
    if (schema === undefined) {
      const answer = await generateText({ ...call, system: instructions });
      if (!answer.text.trim()) throw Error("El resolutor no devolvió contenido");
      return answer.text;
    }
    // Models that ignore response_format still learn the shape from the instructions.
    const system = `${instructions}\n\nResponde solo con un JSON que cumpla este esquema:\n${JSON.stringify(schema)}`;
    let value: unknown;
    try {
      value = (await generateText({ ...call, system, output: Output.object({ schema: jsonSchema(schema as Parameters<typeof jsonSchema>[0]) }) })).output;
    } catch (error) {
      if (!NoObjectGeneratedError.isInstance(error)) throw error;
      value = answerJson(error.text ?? "");
    }
    return conforming(value, schema);
  } catch (error) {
    throw inferenceError(error, secret);
  }
}
export const digestSchema = () => ({
  type: "object",
  properties: { title: { type: "string" }, summary: { type: "string" }, tags: { type: "array", items: { type: "string" } } },
  required: ["title", "summary", "tags"],
  additionalProperties: false,
});
