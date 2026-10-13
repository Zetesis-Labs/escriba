import type { Resolver } from "../types";
import { device, macOS, type Platform } from "./platform";

export type Role = "stt" | "llm";

export const roleLabel = (role: Role) => (role === "stt" ? "STT" : "LLMs");
export const localName = (role: Role, platform: Platform = macOS) =>
  role === "llm" ? "Apple Intelligence" : platform.system === "linux" ? "Whisper · en este equipo" : "Whisper en este Mac";
export const hasLocal = (role: Role, platform: Platform = macOS) => role === "stt" || platform.system !== "linux";

export const resolversFooter = (role: Role, platform: Platform = macOS) =>
  `Cada receta elige con qué ${role === "stt" ? "transcribir" : "resumir"}, en Recetas. ${
    hasLocal(role, platform) ? `La que no elige usa ${localName(role, platform)}.` : "La que no elige no puede resumir."
  }`;

export const removedResolverNote = (role: Role, platform: Platform = macOS) =>
  `Se borra su clave. ${hasLocal(role, platform) ? `Las recetas que lo usaban pasan a ${localName(role, platform)}.` : "Las recetas que lo usaban se quedan sin LLM."}`;
export const localId = (role: Role) => (role === "stt" ? "local-stt" : "local-llm");

export interface RemotePreset {
  name: string;
  baseURL: string;
  model: string;
}

const other: RemotePreset = { name: "Otro servicio compatible", baseURL: "", model: "" };

export function remotePresets(role: Role): RemotePreset[] {
  return role === "stt"
    ? [
        { name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "whisper-1" },
        { name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo" },
        other,
      ]
    : [
        { name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "" },
        { name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "" },
        { name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "" },
        { name: "LM Studio", baseURL: "http://localhost:1234/v1", model: "" },
        { name: "Ollama", baseURL: "http://localhost:11434/v1", model: "" },
        other,
      ];
}

export function presetFor(role: Role, baseURL: string) {
  return remotePresets(role).find((preset) => preset.baseURL && preset.baseURL === baseURL)?.name ?? other.name;
}

export function nextResolverName(base: string, taken: string[]) {
  if (!taken.includes(base)) return base;
  for (let number = 2; ; number++) if (!taken.includes(`${base} ${number}`)) return `${base} ${number}`;
}

export function isPrivateHost(raw: string) {
  const host = raw.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".local") || host === "::1") return true;
  if (host.startsWith("fc") || host.startsWith("fd")) return host.includes(":");
  const parts = host.split(".");
  const octets = parts.map(Number);
  if (parts.length !== 4 || octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) return false;
  const [a, b] = octets;
  return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) || (a === 100 && b >= 64 && b <= 127);
}

export function remoteURLProblem(raw: string) {
  const text = raw.trim();
  if (!text) return "Escribe la URL de la API.";
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return "La URL tiene que empezar por http:// o https://.";
  }
  if (!["http:", "https:"].includes(url.protocol) || !url.hostname) return "La URL tiene que empezar por http:// o https://.";
  if (url.username || url.password || url.search || url.hash || text.includes("?") || text.includes("#"))
    return "La URL no puede llevar usuario, contraseña ni parámetros.";
  if (url.protocol !== "https:" && !isPrivateHost(url.hostname)) return "Usa https:// para un servicio fuera de tu red.";
  return null;
}

export function resolverProblem(resolver: Pick<Resolver, "local" | "url" | "model">, localProblem: string | null) {
  if (resolver.local) return localProblem;
  const urlProblem = remoteURLProblem(resolver.url ?? "");
  if (urlProblem) return urlProblem;
  return resolver.model?.trim() ? null : "Elige el modelo.";
}

export function resolverSubtitle(resolver: Resolver, problem: string | null, platform: Platform = macOS) {
  if (problem && !resolver.local) return "Sin terminar de configurar";
  if (resolver.local) return `En este ${device(platform)}`;
  let host = resolver.url ?? "";
  try {
    host = new URL(resolver.url ?? "").host || host;
  } catch {
    host = resolver.url ?? "";
  }
  return [host, resolver.model ?? ""].filter(Boolean).join(" · ");
}

export const sampleTranscript = [
  "Ana: ¿Cómo vamos con el lanzamiento del jueves?",
  "Luis: La migración no llega; propongo moverla una semana.",
  "Ana: Vale, y avisamos a soporte hoy mismo.",
].join("\n");

export const sampleInstructions = [
  "Resume la grabación con fidelidad. Devuelve título, resumen y etiquetas. No inventes hechos.",
  "Idioma de la respuesta: el del texto.",
].join("\n");

export function localProblem(role: Role, status: { whisper?: { available?: boolean }; llm?: { available?: boolean; reason?: string | null } } | null) {
  if (!status) return null;
  if (role === "stt") return status.whisper?.available ? null : "el modelo de Whisper no está descargado; descárgalo aquí abajo";
  return status.llm?.available ? null : status.llm?.reason || "Apple Intelligence no está disponible en este Mac";
}

export function bytesLabel(bytes: number) {
  return new Intl.NumberFormat("es-ES", { style: "unit", unit: bytes >= 1e9 ? "gigabyte" : "megabyte", maximumFractionDigits: 1 }).format(
    bytes >= 1e9 ? bytes / 1e9 : bytes / 1e6,
  );
}
