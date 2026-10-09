import { AlertTriangle } from "lucide-react";
import { clockStamp, recordingExcerpt, recordingTitle, recordingWhen, visibleTags } from "../core/presentation";
import type { Account, Destination, Recording } from "../types";
import { currentVersion, publishedNames, transcriptDuration } from "./model";

export const displayTitle = (recording: Recording) => {
  const version = currentVersion(recording);
  return recordingTitle(version?.digest, version?.transcript.text, new Date(recording.createdAt));
};

export function TagChips({ tags, limit }: { tags: string[]; limit?: number }) {
  const visible = visibleTags(tags, limit ?? Number.MAX_SAFE_INTEGER);
  return (
    <div className="tag-chips">
      {visible.shown.map((tag) => (
        <span className="tag-chip" key={tag}>
          {tag}
        </span>
      ))}
      {visible.hidden > 0 && <span className="secondary font-caption">+{visible.hidden}</span>}
    </div>
  );
}

const chip: Partial<Record<Recording["status"], [string, string]>> = {
  pending: ["En cola", "gray"],
  processing: ["Transcribiendo", "blue"],
  failed: ["Error", "orange"],
};

export function StatusChip({ status }: { status: Recording["status"] }) {
  const descriptor = chip[status];
  if (!descriptor) return null;
  return <span className={`status-chip ${descriptor[1]}`}>{descriptor[0]}</span>;
}

export function RecordingRow({ recording, origin, now, destinations, accounts }: { recording: Recording; origin: string; now: Date; destinations: Destination[]; accounts: Account[] }) {
  const version = currentVersion(recording);
  const duration = transcriptDuration(version?.transcript);
  const excerpt = recordingExcerpt(version?.digest, version?.transcript.text);
  const tags = version?.digest?.tags ?? [];
  const published = publishedNames(recording, destinations, accounts);
  const footer = [origin, recordingWhen(new Date(recording.createdAt), now), published.length ? `en ${published.join(" y ")}` : null]
    .filter(Boolean)
    .join(" · ");
  const problem = recording.publications.find((publication) => publication.error)?.error;
  return (
    <div className="recording-row">
      <div className="row-heading">
        <span className="row-title font-headline">{displayTitle(recording)}</span>
        {duration !== undefined && <span className="font-caption secondary monospaced-digits">{clockStamp(duration)}</span>}
      </div>
      {excerpt && <div className="row-excerpt font-callout secondary">{excerpt}</div>}
      {tags.length > 0 && <TagChips tags={tags} limit={3} />}
      <div className="row-footer font-caption">
        <StatusChip status={recording.status} />
        <span className="tertiary row-footer-text">{footer}</span>
        {problem && (
          <span className="warning" title={`No se publicó: ${problem}`}>
            <AlertTriangle size={12} strokeWidth={2} />
          </span>
        )}
      </div>
    </div>
  );
}
