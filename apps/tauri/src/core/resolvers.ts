import type { Resolver } from "../types";
import { device, macOS, whisperDownloadLabel, whisperName, type Platform } from "./platform";

export type Role = "stt" | "llm";

export const roleLabel = (role: Role) => (role === "stt" ? "STT" : "LLMs");
export const localName = (role: Role, platform: Platform = macOS) =>
  role === "llm" ? "Apple Intelligence" : whisperName(platform.system);
export const hasLocal = (role: Role, platform: Platform = macOS) => role === "stt" || platform.bundledLlm;

type Listed = Pick<Resolver, "id" | "name" | "role" | "local" | "enabled">;

// A recipe that picks no STT uses the first local Whisper left in the list.
export const defaultLocalStt = <T extends { role?: unknown; local?: unknown; enabled?: unknown }>(resolvers: T[]): T | undefined =>
  resolvers.find((resolver) => resolver.role === "stt" && resolver.local === true && resolver.enabled !== false);

// What a recipe that picks nothing uses; null when nothing is left.
function fallbackName(role: Role, platform: Platform, resolvers?: Listed[]) {
  if (!hasLocal(role, platform)) return null;
  if (role === "llm" || !resolvers) return localName(role, platform);
  const local = defaultLocalStt(resolvers);
  return local ? resolverName(local as Resolver, role, platform) : null;
}

export const resolversFooter = (role: Role, platform: Platform = macOS, resolvers?: Listed[]) => {
  const fallback = fallbackName(role, platform, resolvers);
  const rest = fallback
    ? `La que no elige usa ${fallback}.`
    : role === "stt"
      ? "La que no elige espera hasta que añadas un Whisper local."
      : "La que no elige no puede resumir.";
  return `Cada receta elige con qué ${role === "stt" ? "transcribir" : "resumir"}, en Recetas. ${rest}`;
};

export const movedRecipesNote = (role: Role, platform: Platform = macOS, resolvers?: Listed[]) => {
  const fallback = fallbackName(role, platform, resolvers);
  if (fallback) return `Las recetas que lo usaban pasan a ${fallback}.`;
  return role === "stt" ? "Las recetas que lo usaban esperan hasta que añadas un Whisper local." : "Las recetas que lo usaban se quedan sin LLM.";
};

export const removedResolverNote = (role: Role, platform: Platform = macOS, resolvers?: Listed[]) =>
  `Se borra su clave. ${movedRecipesNote(role, platform, resolvers)}`;
export const localId = (role: Role) => (role === "stt" ? "local-stt" : "local-llm");

export const LLM_PROVIDERS = ["openai-compatible", "anthropic", "google", "mistral"] as const;
export type LlmProvider = (typeof LLM_PROVIDERS)[number];

// A resolver saved before native providers has none and speaks the OpenAI-compatible API.
export function llmProvider(resolver: { role?: unknown; provider?: unknown }): LlmProvider {
  const provider = resolver.provider ?? "openai-compatible";
  if (!LLM_PROVIDERS.includes(provider as LlmProvider)) throw Error("Proveedor de resolutor no válido");
  if (resolver.role === "stt" && provider !== "openai-compatible") throw Error("Los STT remotos usan un servicio compatible con OpenAI");
  return provider as LlmProvider;
}

export interface RemotePreset {
  name: string;
  provider: LlmProvider;
  baseURL: string;
  model: string;
}

const compatible = (name: string, baseURL: string, model = ""): RemotePreset => ({ name, provider: "openai-compatible", baseURL, model });
const other = compatible("Otro servicio compatible", "");
const native: RemotePreset[] = [
  { name: "Anthropic", provider: "anthropic", baseURL: "https://api.anthropic.com/v1", model: "" },
  { name: "Google Gemini", provider: "google", baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "" },
  { name: "Mistral", provider: "mistral", baseURL: "https://api.mistral.ai/v1", model: "" },
];

export function remotePresets(role: Role): RemotePreset[] {
  return role === "stt"
    ? [compatible("OpenAI", "https://api.openai.com/v1", "whisper-1"), compatible("Groq", "https://api.groq.com/openai/v1", "whisper-large-v3-turbo"), other]
    : [
        compatible("OpenAI", "https://api.openai.com/v1"),
        ...native,
        compatible("OpenRouter", "https://openrouter.ai/api/v1"),
        compatible("Groq", "https://api.groq.com/openai/v1"),
        compatible("LM Studio", "http://localhost:1234/v1"),
        compatible("Ollama", "http://localhost:11434/v1"),
        other,
      ];
}

export function presetFor(role: Role, baseURL: string, provider: LlmProvider = "openai-compatible") {
  const presets = remotePresets(role);
  if (provider !== "openai-compatible") return presets.find((preset) => preset.provider === provider)?.name ?? other.name;
  return presets.find((preset) => preset.provider === provider && preset.baseURL && preset.baseURL === baseURL)?.name ?? other.name;
}

export function remoteSection(role: Role, provider: LlmProvider, platform: Platform = macOS) {
  const from = `sale del ${device(platform)}`;
  if (role === "stt")
    return {
      header: "Servicio compatible con OpenAI",
      footer: `El audio de cada nota ${from} hacia este servicio. Con un servicio remoto no se detectan hablantes. OpenAI y Groq admiten audios de hasta 25 MB.`,
      keyPlaceholder: "Vacía si el servicio no la pide",
    };
  if (provider === "openai-compatible")
    return {
      header: "Servicio compatible con OpenAI",
      footer: `El texto de cada nota ${from} hacia este servicio. Sirve cualquier API compatible con OpenAI: OpenAI, OpenRouter, Groq o, en tu red, LM Studio y Ollama. Anthropic, Google Gemini y Mistral tienen su propia opción en Servicio.`,
      keyPlaceholder: "Vacía si el servicio no la pide",
    };
  const name = presetFor(role, "", provider);
  return { header: name, footer: `El texto de cada nota ${from} hacia ${name}, con su propia API.`, keyPlaceholder: "Obligatoria" };
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
  if (resolver.local) return [`En este ${device(platform)}`, isAddedModel(resolver) ? resolver.model : ""].filter(Boolean).join(" · ");
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

export interface WhisperCatalog {
  default: string;
  models: { model: string; label: string; bytes: number; installed: boolean }[];
}

// Each Whisper model added in STT is a local resolver of its own.
export const isAddedModel = (resolver: Pick<Resolver, "id" | "local">) => resolver.local && resolver.id.startsWith("local-stt-");
// The default Whisper goes only where the catalog lets it come back through «+».
export const removable = (resolver: Pick<Resolver, "id" | "local">, catalog: WhisperCatalog | null) =>
  !resolver.local || isAddedModel(resolver) || (resolver.id === "local-stt" && catalog !== null);
export const resolverName = (resolver: Resolver, role: Role, platform: Platform = macOS) =>
  resolver.local && !isAddedModel(resolver) ? localName(role, platform) : resolver.name;

export function addableModels(catalog: WhisperCatalog | null, resolvers: Pick<Resolver, "id" | "local" | "model">[]) {
  if (!catalog) return [];
  const present = new Set(resolvers.filter(isAddedModel).map((resolver) => resolver.model));
  const hasDefault = resolvers.some((resolver) => resolver.local && resolver.id === "local-stt");
  return catalog.models
    .filter((entry) => !(hasDefault && entry.model === catalog.default) && !present.has(entry.model))
    .map((entry) => ({ model: entry.model, title: `Whisper · ${entry.label} (unos ${bytesLabel(entry.bytes)})` }));
}

export function addedModelProblem(resolver: Pick<Resolver, "id" | "local" | "model">, catalog: WhisperCatalog | null) {
  if (!catalog || !isAddedModel(resolver)) return null;
  return catalog.models.find((entry) => entry.model === resolver.model)?.installed ? null : "el modelo no está descargado; descárgalo aquí abajo";
}

export function downloadLabel(model: string, catalog: WhisperCatalog | null, platform: Platform = macOS) {
  const entry = catalog?.models.find((candidate) => candidate.model === model);
  return entry ? `Descargar (unos ${bytesLabel(entry.bytes)})` : whisperDownloadLabel(platform);
}
