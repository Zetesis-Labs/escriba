import type { Segment } from "../types";
import type { TranscriptSelectionRange } from "./transcriptEditing";

export interface TranscriptGroup {
  speaker: string | null;
  indices: number[];
}

export function transcriptGroups(segments: readonly Segment[]): TranscriptGroup[] {
  const groups: TranscriptGroup[] = [];
  segments.forEach((segment, index) => {
    const speaker = segment.speaker || null;
    const previous = groups.at(-1);
    if (previous && previous.speaker === speaker) previous.indices.push(index);
    else groups.push({ speaker, indices: [index] });
  });
  return groups;
}

export function groupSelectionRanges(group: TranscriptGroup, segments: readonly Segment[]): TranscriptSelectionRange[] {
  return group.indices.map((index) => ({ segment: index, start: 0, end: segments[index].text.length }));
}
