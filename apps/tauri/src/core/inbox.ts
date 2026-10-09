import type { Segment, Transcript } from "../types";

export const audioExtensions = ["m4a", "mp3", "wav", "aac", "flac", "opus", "ogg", "caf", "aiff", "aif", "mp4", "mov"];

const fileName = (path: string) => path.split("/").at(-1) ?? path;

export const isSupportedAudio = (path: string) => audioExtensions.includes(fileName(path).split(".").at(-1)?.toLowerCase() ?? "");

export interface ImportOutcome {
  added: string[];
  rejected: string[];
  failed: string[];
}

export function importPlan(paths: string[]) {
  return { accepted: paths.filter(isSupportedAudio), rejected: paths.filter((path) => !isSupportedAudio(path)).map(fileName) };
}

export function importNotice(outcome: ImportOutcome) {
  const parts: string[] = [];
  if (outcome.added.length === 1) parts.push(`«${outcome.added[0]}» añadida; se transcribe enseguida.`);
  else if (outcome.added.length > 1) parts.push(`${outcome.added.length} grabaciones añadidas; se transcriben enseguida.`);
  if (outcome.rejected.length === 1) parts.push(`«${outcome.rejected[0]}» no es un audio que Escriba sepa leer.`);
  else if (outcome.rejected.length > 1) parts.push(`${outcome.rejected.length} ficheros no son audio que Escriba sepa leer.`);
  if (outcome.failed.length === 1) parts.push(`No se pudo copiar «${outcome.failed[0]}».`);
  else if (outcome.failed.length > 1) parts.push(`No se pudieron copiar ${outcome.failed.length} ficheros.`);
  return parts.length ? parts.join(" ") : null;
}

export { fileName };

export function relabelled(transcript: Transcript, speakers: string[], target: string): Transcript {
  const segments: Segment[] = transcript.segments.map((segment) =>
    segment.speaker && speakers.includes(segment.speaker) ? { ...segment, speaker: target } : segment,
  );
  return { ...transcript, segments };
}
