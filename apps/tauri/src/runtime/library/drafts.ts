import { z } from "zod";
import { canonical, clone, isObject, newId, now, sha256, text, type Json } from "./json";
import { readTranscript, transcriptSchema, type Recording, type Transcript, type Version } from "./model";
import type { SpeakerVoice } from "./voices";

const draftDigestSchema = z.looseObject({ title: z.string(), summary: z.string(), description: z.string().nullish(), tags: z.array(z.string()) });
const draftContentSchema = z.strictObject({
  title: z.string(),
  transcript: transcriptSchema,
  digest: draftDigestSchema.nullable(),
  data: z.json(),
});
export type DraftContent = z.infer<typeof draftContentSchema>;
export interface NoteDraft {
  id: string;
  recordingId: string;
  baseVersionId: string;
  baseFingerprint: string;
  revision: number;
  createdAt: string;
  updatedAt: string;
  content: DraftContent;
}
export const draftFingerprint = (version: Version, title: string | null | undefined) => sha256(canonical([version, title ?? null]));
export function currentVersion(record: Recording): Version {
  const versions = record.versions ?? [];
  const chosen =
    versions.find((version) => version.id === record.currentVersionId) ??
    [...versions].sort((a, b) => ((a.createdAt ?? "") < (b.createdAt ?? "") ? 1 : (a.createdAt ?? "") > (b.createdAt ?? "") ? -1 : 0))[0];
  if (!chosen) throw Error("La nota no tiene una versión vigente");
  return chosen;
}
export function draftContent(record: Recording, version: Version): DraftContent {
  const extraTitle = (version as Record<string, unknown>).title;
  const digestTitle = isObject(version.digest) ? version.digest.title : undefined;
  const title = typeof extraTitle === "string" ? extraTitle : typeof digestTitle === "string" ? digestTitle : typeof record.title === "string" ? record.title : "";
  const parsed = draftContentSchema.safeParse({ title, transcript: version.transcript ?? undefined, digest: version.digest ?? null, data: version.data ?? null });
  if (!parsed.success) throw Error("La versión no tiene un formato editable válido");
  const content = clone(parsed.data);
  if (content.digest) content.digest.title = content.title;
  return content;
}
export function readDraft(value: unknown): NoteDraft {
  if (
    !isObject(value) || typeof value.id !== "string" || typeof value.recordingId !== "string" || typeof value.baseVersionId !== "string" ||
    typeof value.baseFingerprint !== "string" || typeof value.revision !== "number" || typeof value.createdAt !== "string" || typeof value.updatedAt !== "string"
  )
    throw Error("Borrador guardado inválido");
  const content = draftContentSchema.safeParse(value.content);
  if (!content.success) throw Error("Borrador guardado inválido");
  return { id: value.id, recordingId: value.recordingId, baseVersionId: value.baseVersionId, baseFingerprint: value.baseFingerprint, revision: value.revision, createdAt: value.createdAt, updatedAt: value.updatedAt, content: content.data };
}
export function parseDraftContent(value: unknown): DraftContent {
  const parsed = draftContentSchema.safeParse(value);
  if (!parsed.success) throw Error("Contenido del borrador inválido");
  return parsed.data;
}
export function validateContent(content: DraftContent) {
  for (const segment of content.transcript.segments) {
    if (segment.start < 0 || segment.end < segment.start) throw Error("Intervalo de segmento inválido");
    for (const word of segment.words ?? []) if (word.start < 0 || word.end < word.start) throw Error("Intervalo de palabra inválido");
  }
  if (typeof content.transcript.duration === "number" && content.transcript.duration < 0) throw Error("Duración inválida");
}
export function conservativeVoices(source: Transcript, corrected: Transcript, voices: SpeakerVoice[]): SpeakerVoice[] {
  const uniqueIntervals = (transcript: Transcript) => {
    const intervals = new Map<string, number | null>();
    transcript.segments.forEach((segment, index) => {
      const key = `${segment.start}|${segment.end}`;
      intervals.set(key, intervals.has(key) ? null : index);
    });
    return intervals;
  };
  const sourceIntervals = uniqueIntervals(source);
  const correctedIntervals = uniqueIntervals(corrected);
  const labelCounts = new Map<string, number>();
  for (const segment of corrected.segments) if (typeof segment.speaker === "string") labelCounts.set(segment.speaker, (labelCounts.get(segment.speaker) ?? 0) + 1);
  const result: SpeakerVoice[] = [];
  for (const voice of voices) {
    let label: string | undefined;
    let matched = 0;
    let ambiguous = false;
    for (const segment of source.segments.filter((segment) => segment.speaker === voice.speaker)) {
      const key = `${segment.start}|${segment.end}`;
      const sourceIndex = sourceIntervals.get(key);
      const correctedIndex = correctedIntervals.get(key);
      const next = typeof correctedIndex === "number" ? corrected.segments[correctedIndex]?.speaker : undefined;
      if (typeof sourceIndex !== "number" || typeof correctedIndex !== "number" || typeof next !== "string" || (label !== undefined && label !== next)) {
        ambiguous = true;
        break;
      }
      label = next;
      matched += 1;
    }
    if (ambiguous || label === undefined || labelCounts.get(label) !== matched) continue;
    result.push({ ...voice, speaker: label });
  }
  return result;
}
export interface DraftRequest {
  key: string;
  draftId: string;
  revision: number;
}
export function draftRequest(params: Json): DraftRequest {
  const key = text(params, "recordingId");
  const draftId = text(params, "draftId");
  const revision = isObject(params) ? params.expectedRevision : undefined;
  if (typeof revision !== "number" || !Number.isInteger(revision) || revision < 0) throw Error("Falta expectedRevision");
  return { key, draftId, revision };
}
export const newDraft = (recordingId: string, base: Version, record: Recording): NoteDraft => ({
  id: newId(),
  recordingId,
  baseVersionId: base.id,
  baseFingerprint: draftFingerprint(base, record.title),
  revision: 0,
  createdAt: now(),
  updatedAt: now(),
  content: draftContent(record, base),
});
export const readDraftTranscript = (value: unknown) => readTranscript(value);
