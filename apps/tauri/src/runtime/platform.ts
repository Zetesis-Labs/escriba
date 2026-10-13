import type { Json } from "./library/json";

// Linux has no bundled LLM: summarizing and asking need a resolver.
export const defaultResolvers = (platform: NodeJS.Platform = process.platform): Json[] => [
  {
    id: "local-stt",
    name: platform === "linux" ? "Whisper · en este equipo" : "Whisper · en este Mac",
    role: "stt",
    local: true,
    enabled: true,
    model: "openai_whisper-large-v3-v20240930",
  },
  ...(platform === "linux" ? [] : [{ id: "local-llm", name: "Apple Intelligence", role: "llm", local: true, enabled: true }]),
];

export const localSttTryProblem = (platform: NodeJS.Platform = process.platform) =>
  `${platform === "linux" ? "Whisper · en este equipo" : "Whisper en este Mac"} no tiene prueba`;
