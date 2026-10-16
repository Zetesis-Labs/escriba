import type { Digest, JSONObject, JSONValue, Recording, Transcript, Version } from "../types";
import { reusableTranscription } from "./transcriptionMemory";

export interface WorkingNote {
  readonly handle: string;
  readonly key: string;
  readonly origin?: Version;
  readonly editing: boolean;
  versionId?: string;
  backend?: string;
  transcript?: Transcript;
  inputs?: JSONObject;
  hasVoices?: boolean;
  voicesFrom?: string | null;
  digest?: Digest | null;
  data?: JSONValue;
  changed: boolean;
}

export type TranscriptionPlan = { kind: "keep" } | { kind: "reuse"; version: Version } | { kind: "transcribe" };

export function openNote(handle: string, key: string, origin: Version | undefined, editing: boolean): WorkingNote {
  if (editing && !origin) throw Error("No hay ninguna versión que editar");
  return {
    handle,
    key,
    origin,
    editing,
    changed: false,
    ...(origin
      ? {
          ...(editing ? { versionId: origin.id } : {}),
          backend: origin.backend,
          transcript: origin.transcript,
          inputs: origin.inputs,
          hasVoices: origin.hasVoices,
          digest: origin.digest ?? null,
          data: origin.data ?? null,
        }
      : {}),
  };
}

export function transcriptionPlan(note: WorkingNote, inputs: JSONObject, versions: readonly Version[]): TranscriptionPlan {
  if (note.transcript && note.inputs && reusableTranscription({ inputs: note.inputs, hasVoices: note.hasVoices }, inputs))
    return { kind: "keep" };
  const version = [...versions].reverse().find((candidate) => reusableTranscription(candidate, inputs));
  return version ? { kind: "reuse", version } : { kind: "transcribe" };
}

export function withTranscript(
  note: WorkingNote,
  change: { transcript: Transcript; inputs: JSONObject; backend: string; hasVoices: boolean; voicesFrom: string | null },
) {
  Object.assign(note, change, { changed: true });
}

export function withDigest(note: WorkingNote, digest: Digest) {
  note.digest = digest;
  note.changed = true;
}

export function withData(note: WorkingNote, data: JSONValue): boolean {
  if (canonicalJSON(data) === canonicalJSON(note.data ?? null)) return false;
  note.data = data;
  note.changed = true;
  return true;
}

export function confirmedVersionId(note: WorkingNote): string | undefined {
  return note.versionId ?? note.origin?.id;
}

export function versionSaveParams(note: WorkingNote, recordingId: string, recipeId: string, jobId?: string): JSONObject {
  if (!note.transcript) throw Error("La nota aún no está transcrita");
  return {
    recordingId,
    transcript: note.transcript as unknown as JSONValue,
    backend: note.backend ?? "local",
    recipeId,
    inputs: note.inputs ?? {},
    digest: (note.digest ?? null) as unknown as JSONValue,
    data: note.data ?? null,
    voicesFrom: note.voicesFrom === undefined ? (note.origin?.id ?? null) : note.voicesFrom,
    select: false,
    ...(note.origin ? { sourceVersionId: note.origin.id } : {}),
    ...(jobId ? { job: { id: jobId, note: note.key } } : {}),
  };
}

export function versionUpdateParams(note: WorkingNote, recordingId: string, versionId: string, transcribed: boolean): JSONObject {
  return {
    recordingId,
    versionId,
    digest: (note.digest ?? null) as unknown as JSONValue,
    data: note.data ?? null,
    ...(transcribed && note.transcript
      ? {
          transcript: note.transcript as unknown as JSONValue,
          inputs: note.inputs ?? {},
          backend: note.backend ?? "local",
          voicesFrom: note.voicesFrom ?? null,
        }
      : {}),
  };
}

export function noteView(note: WorkingNote, recording: Recording) {
  const number = (id: string | undefined) => {
    const index = id === undefined ? -1 : recording.versions.findIndex((version) => version.id === id);
    return index < 0 ? null : index + 1;
  };
  const transcript = note.transcript ?? { text: "", segments: [] };
  return {
    handle: note.handle,
    clave: recording.id,
    version: note.versionId ? number(note.versionId) : note.changed ? null : number(note.origin?.id),
    origen: number(note.origin?.id),
    texto: transcript.text,
    hablantes: [...new Set(transcript.segments.map((segment) => segment.speaker).filter(Boolean))],
    segmentos: transcript.segments.map((segment) => ({
      inicio: segment.start,
      fin: segment.end,
      texto: segment.text,
      hablante: segment.speaker || null,
      palabras: (segment.words || []).map((word) => ({ inicio: word.start, fin: word.end, texto: word.text })),
    })),
    resumen: note.digest ? { titulo: note.digest.title, texto: note.digest.summary, etiquetas: note.digest.tags } : null,
    datos: note.data ?? null,
  };
}

export function versionsView(recording: Recording, baseId: string | undefined) {
  return recording.versions.map((version, index) => ({
    clave: version.id,
    numero: index + 1,
    fecha: version.createdAt,
    origen: version.backend === "correccion" || version.backend === "manual" ? "correccion" : "receta",
    receta: version.recipeId ?? null,
    vigente: version.id === recording.currentVersionId,
    abierta: version.id === baseId,
    criterios: version.inputs ? transcriptionOptions(version.inputs) : null,
    tiene: {
      hablantes: version.transcript.segments.some((segment) => Boolean(segment.speaker)),
      resumen: Boolean(version.digest),
      datos: version.data !== undefined && version.data !== null,
    },
  }));
}

function transcriptionOptions(inputs: JSONObject) {
  return {
    stt: typeof inputs.backend === "string" ? inputs.backend : undefined,
    idioma: typeof inputs.language === "string" ? inputs.language : null,
    hablantes: { detectar: inputs.diarize === true, cuantos: typeof inputs.speakers === "number" ? inputs.speakers : null },
  };
}

function canonicalJSON(value: unknown): string {
  return JSON.stringify(value, (_key, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(Object.entries(item).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : item,
  );
}
