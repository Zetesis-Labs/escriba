import { z } from "zod";
import type { Json } from "./json";

const json: z.ZodType<Json> = z.json() as z.ZodType<Json>;
const jsonNumber = z.number().finite();
const field = <T extends z.ZodTypeAny>(schema: T) => schema.nullish();

export const wordSchema = z.looseObject({ start: jsonNumber, end: jsonNumber, text: z.string() });
export const segmentSchema = z.looseObject({
  start: jsonNumber,
  end: jsonNumber,
  text: z.string(),
  speaker: field(z.string()),
  words: field(z.array(wordSchema)),
});
export const recognitionSchema = z.looseObject({ speaker: z.string(), person: z.string(), distance: jsonNumber });
export const transcriptSchema = z.looseObject({
  text: z.string(),
  segments: z.array(segmentSchema),
  duration: field(jsonNumber),
  language: field(z.string()),
  recognitions: field(z.array(recognitionSchema)),
});
export const versionSchema = z.looseObject({
  id: z.string(),
  createdAt: field(z.string()),
  backend: field(z.string()),
  transcript: field(transcriptSchema),
  hasVoices: field(z.boolean()),
  recipeId: field(z.string()),
  digest: field(json),
  data: field(json),
  inputs: field(json),
});
export const recordingStatusSchema = z.enum(["pending", "processing", "done", "failed", "discarded"]);
export const recordingSchema = z.looseObject({
  id: z.string(),
  status: recordingStatusSchema,
  title: field(z.string()),
  createdAt: field(z.string()),
  source: field(z.string()),
  sourceKey: field(z.string()),
  legacyKey: field(z.string()),
  audioPath: field(z.string()),
  audioHash: field(z.string()),
  duration: field(jsonNumber),
  error: field(z.string()),
  recipeId: field(z.string()),
  currentVersionId: field(z.string()),
  versions: field(z.array(versionSchema)),
  publications: field(z.array(json)),
});
export const watchedFolderSchema = z.looseObject({
  id: z.string(),
  path: z.string(),
  name: z.string(),
  style: field(z.string()),
  enabled: field(z.boolean()),
  accessBookmark: field(json),
});
export const migrationSchema = z.strictObject({ version: z.number().int().nonnegative(), sql: z.string() });
export const ontologyFieldSchema = z.looseObject({});
export const ontologySchema = z.strictObject({
  id: z.string(),
  name: z.string(),
  version: z.number().int().nonnegative(),
  migrations: z.array(migrationSchema),
  collections: z.array(json),
});
export const settingsSchema = z.looseObject({
  projectOntologies: field(z.array(ontologySchema)),
  defaultRecipeId: field(z.string()),
  projectPath: field(z.string()),
  watchedFolders: field(z.array(watchedFolderSchema)),
  whisperModel: field(z.string()),
  launchAtLogin: field(z.boolean()),
  notifyEveryNote: field(z.boolean()),
  jobHistoryDays: field(z.number().int().nonnegative()),
  language: field(z.string()),
  recipeSelectionMigrated: field(z.boolean()),
  voiceMemosSeeded: field(z.boolean()),
  legacyWatchAdopted: field(z.boolean()),
});
export const libraryDataSchema = z.looseObject({
  schemaVersion: z.number().int().nonnegative(),
  recordings: z.array(recordingSchema),
  settings: settingsSchema,
  accounts: json,
  resolvers: json,
  recipes: json,
  destinations: json,
  providers: json.default([]),
});

export type Word = z.infer<typeof wordSchema>;
export type Segment = z.infer<typeof segmentSchema>;
export type Transcript = z.infer<typeof transcriptSchema>;
export type Version = z.infer<typeof versionSchema>;
export type RecordingStatus = z.infer<typeof recordingStatusSchema>;
export type Recording = z.infer<typeof recordingSchema>;
export type WatchedFolder = z.infer<typeof watchedFolderSchema>;
export type Ontology = z.infer<typeof ontologySchema>;
export type Settings = z.infer<typeof settingsSchema>;
export type LibraryData = z.infer<typeof libraryDataSchema>;

function strip<T>(value: T): T {
  if (Array.isArray(value)) return value.map(strip) as T;
  if (value && typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) if (item !== undefined) result[key] = strip(item);
    return result as T;
  }
  return value;
}
function read<T>(schema: z.ZodType<T>, value: unknown, message: string): T {
  const parsed = schema.safeParse(value);
  if (!parsed.success) throw Error(message);
  return strip(parsed.data);
}
export const readLibraryData = (value: unknown) =>
  read(libraryDataSchema, value, "Biblioteca inválida: los datos guardados no cumplen su formato");
export const readRecording = (value: unknown) => read(recordingSchema, value, "Grabación inválida");
export const readVersion = (value: unknown, message = "Versión inválida") => read(versionSchema, value, message);
export const readTranscript = (value: unknown) => read(transcriptSchema, value, "Transcripción inválida");
export const readSettings = (value: unknown) => read(settingsSchema, value, "Ajustes inválidos");
export const readWatchedFolder = (value: unknown) => read(watchedFolderSchema, value, "Carpeta inválida");
export const readOntologies = (value: unknown) => read(z.array(ontologySchema), value, "Ontologías del proyecto inválidas");

export const CATALOGS = ["accounts", "resolvers", "recipes", "destinations", "providers"] as const;
export type Catalog = (typeof CATALOGS)[number];
export function catalog(data: LibraryData, name: string): Json[] {
  if (!(CATALOGS as readonly string[]).includes(name)) throw Error("Colección desconocida");
  const value = data[name as Catalog];
  if (!Array.isArray(value)) throw Error(`${name} inválido`);
  return value;
}
export function setCatalog(data: LibraryData, name: string, items: Json[]) {
  if (!(CATALOGS as readonly string[]).includes(name)) throw Error("Colección desconocida");
  data[name as Catalog] = items;
}
export const present = <T>(value: T | null | undefined): value is T => value !== null && value !== undefined;
