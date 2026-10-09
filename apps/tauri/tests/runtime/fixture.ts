import type { Snapshot } from "../../src/types";
import type { RuntimeContext } from "../../src/runtime/contracts";

export function runtimeContext(
  state: Snapshot,
  recordingId?: unknown,
): RuntimeContext {
  return structuredClone({
    recordings: state.recordings.filter((r) => r.id === recordingId),
    resolvers: state.resolvers,
    recipes: state.recipes,
    accounts: state.accounts,
    destinations: state.destinations,
    settings: {
      defaultRecipeId: state.settings.defaultRecipeId,
      language: state.settings.language,
      whisperModel: state.settings.whisperModel,
    },
  });
}

export const snapshot: Snapshot = {
  recordings: [
    {
      id: "r",
      title: "Nota",
      createdAt: "2026-10-09T10:00:00Z",
      source: "voice",
      audioPath: "/opaque",
      duration: 0,
      status: "pending",
      versions: [],
      publications: [],
    },
  ],
  resolvers: [
    {
      id: "local-stt",
      name: "Whisper",
      role: "stt",
      local: true,
      enabled: true,
    },
    { id: "local-llm", name: "Apple", role: "llm", local: true, enabled: true },
  ],
  recipes: [{ id: "default", name: "Por defecto", kind: "form", values: {} }],
  accounts: [],
  destinations: [],
  settings: {
    defaultRecipeId: "default",
    projectPath: null,
    watchedFolders: [],
    language: "es",
    whisperModel: "large",
    autoProcess: true,
    launchAtLogin: false,
    theme: "system",
  },
  logs: [],
  dataPath: "/library",
};
