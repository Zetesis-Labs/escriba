import type { Json } from "./library/json";

// Each system has its own engine: WhisperKit on macOS, whisper.cpp on Linux.
export const defaultWhisperModel = (platform: NodeJS.Platform = process.platform) =>
  platform === "linux" ? "large-v3-turbo" : "openai_whisper-large-v3-v20240930";

// Linux has no bundled LLM: summarizing and asking need a resolver.
export const defaultResolvers = (platform: NodeJS.Platform = process.platform): Json[] => [
  {
    id: "local-stt",
    name: platform === "linux" ? "Whisper · en este equipo" : "Whisper · en este Mac",
    role: "stt",
    local: true,
    enabled: true,
    model: defaultWhisperModel(platform),
  },
  ...(platform === "linux" ? [] : [{ id: "local-llm", name: "Apple Intelligence", role: "llm", local: true, enabled: true }]),
];

export const localSttTryProblem = (platform: NodeJS.Platform = process.platform) =>
  `${platform === "linux" ? "Whisper · en este equipo" : "Whisper en este Mac"} no tiene prueba`;

// Without a bundled LLM, a recipe that picks none cannot summarize.
export const missingLlm = (resolverId: string, platform: NodeJS.Platform = process.platform) =>
  platform === "linux" && resolverId === "local-llm" ? "La receta no tiene un LLM elegido: elígelo en Recetas" : null;
