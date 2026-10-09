import type { Person, Snapshot } from "../types";

export const demoPeople: Person[] = [
  { name: "Ana", voices: [
    { id: "demo-voice-1", source: "Reunión del lanzamiento", addedAt: "2026-10-09T09:47:00Z", model: "pyannote" },
    { id: "demo-voice-2", source: "muestra de voz", addedAt: "2026-10-08T11:10:00Z", model: "pyannote" },
  ] },
  { name: "Luis", voices: [{ id: "demo-voice-3", source: "Reunión del lanzamiento", addedAt: "2026-10-09T09:47:00Z", model: "pyannote" }] },
];

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
            recognitions: [{ speaker: "Speaker 1", person: "Ana", distance: 0.2 }],
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
          hasVoices: true,
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
    {
      id: "okf-demo",
      name: "OKF",
      provider: "okf",
      enabled: true,
      folder: "/Users/ana/Notas OKF",
    },
  ],
  destinations: [
    {
      id: "notion-demo",
      name: "Notas de trabajo",
      provider: "notion",
      account: "notion-demo",
      enabled: true,
      configuration: {
        source: {
          id: "base-demo",
          title: "Notas",
          databaseTitle: "Diario",
          properties: [
            { name: "Nombre", type: "title" },
            { name: "Fecha", type: "date" },
            { name: "Etiquetas", type: "multi_select" },
            { name: "Resumen", type: "rich_text" },
            { name: "Archivado", type: "checkbox" },
          ],
        },
        columns: { Nombre: "{{titulo}}", Fecha: "{{fecha-iso}}", Etiquetas: "{{etiquetas}}", Resumen: "{{resumen}}" },
        body: "# {{titulo}}\n\n{{resumen}}\n\n{{audio}}\n\n# Transcripción\n{{transcripcion}}",
      },
    },
    {
      id: "okf-demo",
      name: "OKF",
      provider: "okf",
      account: "okf-demo",
      enabled: true,
      configuration: {
        folder: "/Users/ana/Notas OKF",
        documents: [
          { id: "nota", name: "Nota", path: "notas/{{dia}}-{{titulo}}.md", properties: [{ key: "type", value: "Nota de voz" }, { key: "title", value: "{{titulo}}" }, { key: "tags", value: "{{etiquetas}}" }], body: "# Resumen\n\n{{resumen}}\n\n# Transcripción\n\n{{enlace:transcripcion}}" },
          { id: "transcripcion", name: "Transcripción", path: "transcripciones/{{dia}}-{{titulo}}.md", properties: [{ key: "type", value: "Transcripción" }, { key: "title", value: "Transcripción: {{titulo}}" }], body: "De la nota {{enlace:nota}}.\n\n{{transcripcion}}" },
        ],
      },
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
