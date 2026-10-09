import { save } from "@tauri-apps/plugin-dialog";
import { call } from "../api";
import { transcriptExportJSON } from "../core/export";
import { relabelled } from "../core/inbox";
import { clockStamp, renderedTranscript } from "../core/presentation";
import { cancelProcessing, processRecording, publishRecording, summarizeRecording, unpublishRecording } from "../runtime";
import type { Recording, Transcript, Version } from "../types";
import { currentVersion, isPublished } from "./model";
import { displayTitle } from "./RecordingRow";

export async function republish(recording: Recording) {
  const failures: string[] = [];
  for (const publication of recording.publications.filter(isPublished)) {
    try {
      await publishRecording(recording.id, publication.destinationId);
    } catch (failure) {
      failures.push(`${publication.name}: ${failure instanceof Error ? failure.message : String(failure)}`);
    }
  }
  if (failures.length) throw Error(`El cambio se guardó, pero faltó actualizar ${failures.join("; ")}`);
}

export const reprocess = (recording: Recording, recipeId?: string) => processRecording(recording.id, { recipeId, force: true });

export async function chooseVersion(recording: Recording, version: Version) {
  await call("version_select", { recordingId: recording.id, versionId: version.id });
  await republish(recording);
}

async function saveCorrection(recording: Recording, transcript: Transcript) {
  const version = currentVersion(recording);
  await call("version_save", { recordingId: recording.id, transcript, digest: version?.digest ?? null, backend: "correccion" });
  await republish(recording);
}

export function renameSpeaker(recording: Recording, speaker: string, name: string) {
  const transcript = currentVersion(recording)?.transcript;
  const person = name.trim();
  if (!transcript || !person || person === speaker) return Promise.resolve();
  return saveCorrection(recording, relabelled(transcript, [speaker], person));
}

export function mergeSpeaker(recording: Recording, speaker: string, target: string) {
  const transcript = currentVersion(recording)?.transcript;
  if (!transcript) return Promise.resolve();
  return saveCorrection(recording, relabelled(transcript, [speaker], target));
}

export const summarize = (recording: Recording) => summarizeRecording(recording.id);

export async function forgetSummary(recording: Recording) {
  const version = currentVersion(recording);
  if (!version) return;
  await call("version_update", { recordingId: recording.id, versionId: version.id, digest: null });
  await republish(recording);
}

export const publish = (recording: Recording, destinationId: string) => publishRecording(recording.id, destinationId);
export const unpublish = (recording: Recording, destinationId: string) => unpublishRecording(recording.id, destinationId);
export const removeAudio = (recording: Recording) => call("recording_remove_audio", { id: recording.id });

export async function forget(recording: Recording) {
  await call("recording_discard", { id: recording.id });
  if (recording.audioPath) await call("recording_remove_audio", { id: recording.id });
}

export const cancel = (recording: Recording) => cancelProcessing(recording.id);
export const openURL = (url: string) => call("open_url", { url });
export const reveal = (path: string) => call("reveal", { path });
export const okfFile = (accountId: string, path: string, action: "open" | "reveal") => call("okf_file", { accountId, path, action });

export function copyTranscript(transcript: Transcript) {
  return navigator.clipboard.writeText(renderedTranscript(transcript));
}

export function copyJSON(recording: Recording, version: Version) {
  return navigator.clipboard.writeText(
    transcriptExportJSON({
      key: recording.id,
      startedAt: new Date(recording.createdAt),
      source: recording.source,
      backend: version.backend,
      transcript: version.transcript,
    }),
  );
}

const srtTime = (seconds: number) => {
  const total = Math.max(seconds, 0);
  const whole = Math.floor(total);
  const pad = (value: number, size = 2) => String(value).padStart(size, "0");
  return `${pad(Math.floor(whole / 3600))}:${pad(Math.floor((whole % 3600) / 60))}:${pad(whole % 60)},${pad(Math.round((total - whole) * 1000), 3)}`;
};

export const exportFormats = [
  { id: "txt", label: "Texto (.txt)" },
  { id: "md", label: "Markdown (.md)" },
  { id: "srt", label: "Subtítulos (.srt)" },
  { id: "json", label: "JSON (.json)" },
] as const;

function exportContents(format: (typeof exportFormats)[number]["id"], recording: Recording, version: Version) {
  const transcript = version.transcript;
  if (format === "txt") return renderedTranscript(transcript);
  if (format === "json") return transcriptExportJSON({ key: recording.id, startedAt: new Date(recording.createdAt), source: recording.source, backend: version.backend, transcript });
  if (format === "srt")
    return transcript.segments
      .map((segment, index) => `${index + 1}\n${srtTime(segment.start)} --> ${srtTime(segment.end)}\n${segment.speaker ? `${segment.speaker}: ` : ""}${segment.text}\n`)
      .join("\n");
  const lines = [`# ${displayTitle(recording)}`, ""];
  if (version.digest?.summary) lines.push("## Resumen", "", version.digest.summary, "");
  lines.push("## Transcripción", "");
  for (const segment of transcript.segments.length ? transcript.segments : [{ start: 0, end: 0, text: transcript.text, speaker: null }])
    lines.push(`${transcript.segments.length ? `[${clockStamp(segment.start)}] ` : ""}${segment.speaker ? `**${segment.speaker}:** ` : ""}${segment.text}`, "");
  return lines.join("\n");
}

export async function exportTranscript(format: (typeof exportFormats)[number]["id"], recording: Recording, version: Version) {
  const path = await save({ defaultPath: `${displayTitle(recording)}.${format}`, filters: [{ name: format.toUpperCase(), extensions: [format] }] });
  if (!path) return;
  await call("export_file", { path, contents: exportContents(format, recording, version) });
}
