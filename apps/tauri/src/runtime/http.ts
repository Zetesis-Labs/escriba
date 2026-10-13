import { lstat, openAsBlob } from "node:fs";
import { promisify } from "node:util";
import { builtinProviders, type ProviderAccess } from "@escriba/conectores";
import { authorityKey } from "../core/providerAccess";
import { object, text } from "./contracts";

const RESPONSE_LIMIT = 16 * 1024 * 1024;
const MULTIPART_PART_LIMIT = 1000;
const HTTP_TIMEOUT_MS = 120_000;
const lstatAsync = promisify(lstat);

export type HttpTransport = (request: Request) => Promise<Response>;
export interface AudioFile {
  path: string;
  recordingId: string;
}
export interface HttpResult {
  status: number;
  headers: Record<string, string>;
  body: string;
}
const FORBIDDEN_HEADERS = [
  "authorization",
  "proxy-authorization",
  "host",
  "cookie",
  "set-cookie",
  "connection",
  "transfer-encoding",
  "content-length",
  "forwarded",
];
const HEADER_NAME = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
export function safeHeaderName(header: string) {
  if (!HEADER_NAME.test(header)) throw Error("Cabecera HTTP inválida");
  const lower = header.toLowerCase();
  if (
    FORBIDDEN_HEADERS.includes(lower) ||
    lower.startsWith("proxy-") ||
    lower.startsWith("sec-") ||
    lower.startsWith("x-forwarded-")
  )
    throw Error("Cabecera HTTP no permitida");
}
function hasUserinfo(raw: string) {
  const rest = raw.split("://")[1];
  return rest !== undefined && (rest.split(/[/?#]/)[0] ?? "").includes("@");
}
function safeScheme(url: URL) {
  return url.protocol === "https:" || (url.protocol === "http:" && ["127.0.0.1", "[::1]"].includes(url.hostname));
}
export function parseOrigin(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw Error("Origen HTTP inválido");
  }
  if (hasUserinfo(raw) || url.password || url.search || url.hash || url.pathname !== "/" || !safeScheme(url))
    throw Error("Origen HTTP no permitido");
  return url;
}
function sameOrigin(origin: URL, raw: string, target: URL) {
  return (
    !hasUserinfo(raw) &&
    !target.password &&
    !target.hash &&
    safeScheme(target) &&
    target.protocol === origin.protocol &&
    target.hostname === origin.hostname &&
    target.port === origin.port
  );
}
export function validateAccess(access: unknown): ProviderAccess {
  const value = object(access);
  const capability = text(value.capability, "capability");
  const allowed = value.allowedHeaders;
  if (capability === "http") {
    parseOrigin(text(value.origin, "origin"));
    if (!Array.isArray(allowed)) throw Error("Cabeceras autorizadas inválidas");
    for (const header of allowed) {
      if (typeof header !== "string") throw Error("Cabecera autorizada inválida");
      safeHeaderName(header);
    }
    if (value.credential !== undefined && value.credential !== null) {
      const credential = object(value.credential);
      text(credential.label, "label");
      const header = text(credential.header, "header");
      if (header.toLowerCase() !== "authorization") safeHeaderName(header);
      if (allowed.some((name) => String(name).toLowerCase() === header.toLowerCase()))
        throw Error("La cabecera de credencial no puede pasar desde la receta");
      if (credential.prefix !== undefined && (typeof credential.prefix !== "string" || /[\r\n]/.test(credential.prefix)))
        throw Error("Prefijo de credencial inválido");
      if (credential.help !== undefined && typeof credential.help !== "string")
        throw Error("Ayuda de credencial inválida");
    }
  } else if (capability === "folder") {
    if ((value.origin !== undefined && value.origin !== null) || (value.credential !== undefined && value.credential !== null) || !Array.isArray(allowed) || allowed.length)
      throw Error("Permiso de carpeta inválido");
  } else throw Error("Capacidad de proveedor inválida");
  return value as unknown as ProviderAccess;
}
export function validateAccountGrant(grant: unknown): ProviderAccess {
  const access = validateAccess(grant);
  const fields = object(grant);
  if (Object.keys(fields).some((key) => !["capability", "origin", "allowedHeaders", "credential"].includes(key)))
    throw Error("La autorización contiene datos no permitidos");
  if (fields.credential && typeof fields.credential === "object") {
    if (Object.keys(fields.credential).some((key) => !["label", "header", "prefix", "help"].includes(key)))
      throw Error("La definición de credencial contiene datos no permitidos");
  }
  return access;
}
export function accessEquivalent(left: unknown, right: unknown) {
  try {
    return authorityKey(validateAccess(left)) === authorityKey(validateAccess(right));
  } catch {
    return false;
  }
}
function ensureEnabled(account: Record<string, unknown>) {
  if (account.enabled !== true) throw Error("Cuenta desactivada");
}
export function authorizedAccess(
  account: Record<string, unknown>,
  provider: Record<string, unknown> | undefined,
  request: Record<string, unknown>,
  capability: "http" | "folder",
): ProviderAccess {
  ensureEnabled(account);
  const builtin = builtinProviders.find((entry) => entry.id === account.provider);
  const canonical: ProviderAccess | undefined = builtin
    ? {
        capability: builtin.capability,
        ...(builtin.origin ? { origin: builtin.origin } : {}),
        allowedHeaders: builtin.allowedHeaders,
        ...(builtin.credential ? { credential: builtin.credential } : {}),
      }
    : undefined;
  let granted: ProviderAccess;
  if (account.grant !== undefined && account.grant !== null) {
    granted = validateAccountGrant(account.grant);
    if (canonical && !accessEquivalent(granted, canonical))
      throw Error("La autorización de la cuenta no coincide con el proveedor");
  } else if (canonical) granted = canonical;
  else throw Error("Cuenta sin autorización");
  if (granted.capability !== capability) throw Error("Capacidad no autorizada para esta cuenta");
  if (provider && request.expectedGrant === undefined) throw Error("Falta la autorización esperada de la cuenta");
  if (request.expectedGrant !== undefined && !accessEquivalent(request.expectedGrant, granted))
    throw Error("La autorización de la cuenta cambió");
  if (provider && !accessEquivalent(provider, granted))
    throw Error("La definición del proveedor cambió; reautoriza la cuenta");
  return granted;
}
function safeDisposition(value: string) {
  if (!value || /[\r\n"\\/\0]/.test(value)) throw Error("Nombre multipart inválido");
  return value;
}
function redact(value: string, secret?: string) {
  return secret ? value.split(secret).join("[redacted]") : value;
}
function offset(value: Record<string, unknown>, name: string, fallback: number) {
  const raw = value[name];
  if (raw === undefined) return fallback;
  if (typeof raw !== "number" || !Number.isSafeInteger(raw) || raw < 0) throw Error("Rango de audio inválido");
  return raw;
}
async function audioPart(granted: AudioFile, reference: Record<string, unknown>, part: Record<string, unknown>) {
  let size: number;
  try {
    const stat = await lstatAsync(granted.path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw Error("Audio no disponible");
    size = stat.size;
  } catch {
    throw Error("Audio no disponible");
  }
  const start = offset(reference, "start", 0);
  const end = offset(reference, "end", size);
  if (start > end || end > size) throw Error("Rango de audio inválido");
  const blob = (await openAsBlob(granted.path)).slice(start, end, String(part.type ?? "audio/mp4"));
  const filename = safeDisposition(String(part.filename ?? "audio.m4a"));
  return new File([blob], filename, { type: String(part.type ?? "audio/mp4") });
}
export async function httpWithGrant(
  account: Record<string, unknown>,
  grant: ProviderAccess,
  credential: string | undefined,
  request: Record<string, unknown>,
  audio: AudioFile | undefined,
  transport: HttpTransport = fetch,
): Promise<HttpResult> {
  ensureEnabled(account);
  if (!grant.origin) throw Error("Cuenta sin origen HTTP");
  const origin = parseOrigin(grant.origin);
  const rawUrl = text(request.url, "url");
  let target: URL;
  try {
    target = new URL(rawUrl);
  } catch {
    throw Error("URL HTTP inválida");
  }
  if (!sameOrigin(origin, rawUrl, target)) throw Error("URL fuera del origen autorizado");
  const method = String(request.method ?? "GET").toUpperCase();
  if (!["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].includes(method)) throw Error("Método HTTP no permitido");
  const headers = new Headers();
  if (request.headers !== undefined) {
    const given = object(request.headers);
    for (const [name, value] of Object.entries(given)) {
      if (!grant.allowedHeaders.some((header) => header.toLowerCase() === name.toLowerCase()))
        throw Error("Cabecera HTTP no permitida");
      safeHeaderName(name);
      if (typeof value !== "string" || /[\r\n]/.test(value)) throw Error("Cabecera HTTP inválida");
      headers.set(name, value);
    }
  }
  if (request.body !== undefined && request.multipart !== undefined) throw Error("No se puede combinar body y multipart");
  let body: BodyInit | undefined;
  if (request.body !== undefined) {
    if (typeof request.body !== "string") throw Error("Cuerpo HTTP inválido");
    if (request.body.length > RESPONSE_LIMIT) throw Error("Cuerpo HTTP supera 16 MiB");
    body = request.body;
  }
  if (request.multipart !== undefined) {
    if (!Array.isArray(request.multipart)) throw Error("Multipart inválido");
    if (request.multipart.length > MULTIPART_PART_LIMIT) throw Error("Multipart supera 1000 partes");
    const form = new FormData();
    let textBytes = 0;
    for (const raw of request.multipart) {
      const part = object(raw);
      const name = safeDisposition(text(part.name, "name"));
      if (part.audio !== undefined) {
        if (!audio) throw Error("Audio no autorizado");
        const reference = object(part.audio);
        if (reference.recordingId !== audio.recordingId) throw Error("Audio no autorizado para esta grabación");
        form.append(name, await audioPart(audio, reference, part));
      } else {
        const value = text(part.value, "value");
        textBytes += value.length;
        if (textBytes > RESPONSE_LIMIT) throw Error("Multipart supera 16 MiB de texto");
        form.append(name, value);
      }
    }
    body = form;
  }
  if (credential !== undefined) {
    if (!credential || /[\r\n]/.test(credential)) throw Error("Credencial inválida");
    if (!grant.credential) throw Error("Credencial no autorizada");
    const header = grant.credential.header;
    if (header.toLowerCase() !== "authorization") safeHeaderName(header);
    headers.set(header, `${grant.credential.prefix ?? ""}${credential}`);
  } else if (grant.credential) throw Error("La cuenta necesita una credencial");
  let response: Response;
  try {
    response = await transport(
      new Request(target, { method, headers, body, redirect: "manual", signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) }),
    );
  } catch {
    throw Error("No se pudo completar la petición HTTP");
  }
  const picked: Record<string, string> = {};
  for (const name of ["content-type", "retry-after", "request-id"]) {
    const value = response.headers.get(name);
    if (value !== null) picked[name] = redact(value, credential);
  }
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > RESPONSE_LIMIT) throw Error("Respuesta HTTP supera 16 MiB");
  const chunks: Uint8Array[] = [];
  let received = 0;
  if (response.body) {
    const reader = response.body.getReader();
    for (;;) {
      let next: ReadableStreamReadResult<Uint8Array>;
      try {
        next = await reader.read();
      } catch {
        throw Error("No se pudo leer la respuesta HTTP");
      }
      if (next.done) break;
      received += next.value.length;
      if (received > RESPONSE_LIMIT) throw Error("Respuesta HTTP supera 16 MiB");
      chunks.push(next.value);
    }
  }
  const bytes = new Uint8Array(received);
  let position = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, position);
    position += chunk.length;
  }
  return { status: response.status, headers: picked, body: redact(new TextDecoder().decode(bytes), credential) };
}
