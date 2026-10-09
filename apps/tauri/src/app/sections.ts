import { AudioLines, AudioWaveform, Braces, Settings, Share, Sparkles, SquareMenu, Users } from "lucide-react";

export type MainSection = "library" | "people" | "connectors" | "stt" | "llms" | "recipes" | "log" | "settings";

export const sections: { id: MainSection; label: string; icon: typeof AudioLines }[] = [
  { id: "library", label: "Biblioteca", icon: AudioLines },
  { id: "people", label: "Personas", icon: Users },
  { id: "connectors", label: "Conectores", icon: Share },
  { id: "stt", label: "STT", icon: AudioWaveform },
  { id: "llms", label: "LLMs", icon: Sparkles },
  { id: "recipes", label: "Recetas", icon: Braces },
  { id: "log", label: "Registro", icon: SquareMenu },
  { id: "settings", label: "Ajustes", icon: Settings },
];

export function initialSection(search: string): MainSection {
  const asked = new URLSearchParams(search).get("section");
  return sections.some((section) => section.id === asked) ? (asked as MainSection) : "library";
}
