import type { JobState, Recording } from "../types";

const waiting: Partial<Record<Recording["status"], string>> = {
  pending: "En cola",
  processing: "Transcribiendo",
};

export function recordingSubline(recording: Recording, job?: JobState) {
  if (job) return job.stage;
  const version = recording.versions.at(-1);
  return (
    version?.digest?.summary ||
    version?.transcript.text ||
    recording.error ||
    waiting[recording.status] ||
    ""
  );
}
