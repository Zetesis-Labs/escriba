import { macOS, whisperName, type Platform } from "../core/platform";
import platforms from "../generated/platforms.json";
import type { Json } from "./library/json";

// Rust passes what this system offers when it starts the controller; tests and
// tools without it take Rust's table for the system they run on.
export function currentPlatform(env: NodeJS.ProcessEnv = process.env, system: NodeJS.Platform = process.platform): Platform {
  if (env.ESCRIBA_PLATFORM) return JSON.parse(env.ESCRIBA_PLATFORM) as Platform;
  return system === "linux" ? (platforms.linux as Platform) : macOS;
}

export const defaultWhisperModel = (platform: Platform = currentPlatform()) => platform.defaultWhisperModel;

export const defaultResolvers = (platform: Platform = currentPlatform()): Json[] => [
  {
    id: "local-stt",
    // Libraries created on the Mac keep the name they were stored with.
    name: platform.system === "macos" ? "Whisper · en este Mac" : whisperName(platform.system),
    role: "stt",
    local: true,
    enabled: true,
    model: platform.defaultWhisperModel,
  },
  ...(platform.bundledLlm ? [{ id: "local-llm", name: "Apple Intelligence", role: "llm", local: true, enabled: true }] : []),
];

export const localSttTryProblem = (platform: Platform = currentPlatform()) => `${whisperName(platform.system)} no tiene prueba`;

// Without a bundled LLM, a recipe that picks none cannot summarize.
export const missingLlm = (resolverId: string, platform: Platform = currentPlatform()) =>
  !platform.bundledLlm && resolverId === "local-llm" ? "La receta no tiene un LLM elegido: elígelo en Recetas" : null;

// Where folders are authorized, watching one needs its saved authorization.
export const folderBookmarkRequired = (platform: Platform = currentPlatform()) => platform.folderAuthorization;
