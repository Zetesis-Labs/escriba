import type { Snapshot } from "../types";

export const demoSnapshot: Snapshot = {
  recordings: [
    {
      id: "demo-1",
      title: "Reunión del lanzamiento",
      createdAt: "2026-10-09T09:42:00Z",
      source: "reunion-lanzamiento.m4a",
      audioPath: null,
      duration: 187,
      status: "done",
      currentVersionId: "v1",
      recipeId: "default",
      publications: [
        {
          destinationId: "notion-demo",
          name: "Notas de trabajo",
          provider: "notion",
          receipt: {},
          configuration: {},
          updatedAt: "2026-10-09T09:48:00Z",
        },
      ],
      versions: [
        {
          id: "v1",
          createdAt: "2026-10-09T09:47:00Z",
          backend: "WhisperKit",
          recipeId: "default",
          transcript: {
            text: "¿Cómo vamos con el lanzamiento?\nLa migración no llega; propongo moverla una semana.\nVale, y avisamos hoy a soporte.",
            duration: 187,
            segments: [
              {
                start: 0,
                end: 38,
                speaker: "Ana",
                text: "¿Cómo vamos con el lanzamiento?",
              },
              {
                start: 38,
                end: 135,
                speaker: "Luis",
                text: "La migración no llega; propongo moverla una semana.",
              },
              {
                start: 135,
                end: 187,
                speaker: "Ana",
                text: "Vale, y avisamos hoy a soporte.",
              },
            ],
          },
          digest: {
            title: "Reunión del lanzamiento",
            summary:
              "Ana y Luis acuerdan aplazar la migración una semana y avisar hoy a soporte.",
            tags: ["lanzamiento", "migración"],
          },
        },
      ],
    },
    {
      id: "demo-2",
      title: "Ideas para el artículo",
      createdAt: "2026-10-08T16:15:00Z",
      source: "ideas-articulo.m4a",
      audioPath: null,
      duration: 94,
      status: "done",
      currentVersionId: "v2",
      publications: [],
      versions: [
        {
          id: "v2",
          createdAt: "2026-10-08T16:20:00Z",
          backend: "WhisperKit",
          transcript: {
            text: "Abrir con el problema. Después mostrar el ejemplo.",
            segments: [],
          },
        },
      ],
    },
    {
      id: "demo-3",
      title: "Nota del viernes",
      createdAt: "2026-10-07T12:15:00Z",
      source: "nota-viernes.m4a",
      audioPath: null,
      duration: 0,
      status: "pending",
      publications: [],
      versions: [],
    },
  ],
  resolvers: [
    {
      id: "whisper",
      name: "WhisperKit",
      role: "stt",
      local: true,
      enabled: true,
    },
    {
      id: "apple",
      name: "Apple Intelligence",
      role: "llm",
      local: true,
      enabled: true,
    },
  ],
  recipes: [
    {
      id: "default",
      name: "Por defecto",
      kind: "form",
      values: {},
      description: "Transcribe, resume y publica según sus ajustes.",
    },
  ],
  accounts: [
    {
      id: "notion-demo",
      name: "Notion personal",
      provider: "notion",
      enabled: true,
      hasCredential: true,
    },
  ],
  destinations: [
    {
      id: "notion-demo",
      name: "Notas de trabajo",
      provider: "notion",
      account: "notion-demo",
      enabled: true,
      configuration: {},
    },
  ],
  settings: {
    defaultRecipeId: "default",
    projectPath: null,
    watchedFolders: [],
    language: "es",
    whisperModel: "openai_whisper-large-v3_turbo",
    autoProcess: true,
    launchAtLogin: false,
    theme: "system",
  },
  logs: [
    {
      id: "log-1",
      at: "2026-10-09T09:48:00Z",
      level: "info",
      message: "Publicada en Notas de trabajo",
      recordingId: "demo-1",
    },
  ],
  dataPath: "Vista de muestra",
  native: {
    protocolVersion: 1,
    whisper: { available: true },
    llm: { available: true },
  },
};
