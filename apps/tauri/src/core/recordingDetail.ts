import type { Recording } from "../types";

export function recordingRevision(recording: Recording) {
  return JSON.stringify([
    recording.title,
    recording.source,
    recording.duration,
    recording.recipeId ?? null,
    recording.status,
    recording.error ?? null,
    recording.audioPath,
    recording.currentVersionId ?? null,
    recording.versions.map((version) => [
      version.id,
      version.recipeId ?? null,
      version.revision ?? [version.digest?.title ?? null, version.digest?.summary?.length ?? 0, Boolean(version.data)],
    ]),
    recording.publications.map((publication) => [publication.destinationId, publication.updatedAt, publication.error ?? null]),
  ]);
}
