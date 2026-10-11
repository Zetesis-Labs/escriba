import type { Segment, Transcript } from "../types";

export interface TranscriptSelectionRange {
  segment: number;
  start: number;
  end: number;
}

type TimedWord = NonNullable<Segment["words"]>[number];
type AlignedWord = { start: number; end: number; word: TimedWord };

function cloneSegment(segment: Segment): Segment {
  return { ...segment, ...(segment.words ? { words: segment.words.map((word) => ({ ...word })) } : {}) };
}

function segmentAt(transcript: Transcript, index: number): Segment {
  if (!Number.isInteger(index) || index < 0 || index >= transcript.segments.length) {
    throw new RangeError("Índice de segmento fuera de rango");
  }
  return transcript.segments[index];
}

function joinedText(segments: Segment[]): string {
  return segments.map((segment) => segment.text).join(" ");
}

function replacementText(transcript: Transcript, index: number, text: string): string {
  let cursor = 0;
  let target: [number, number] | null = null;
  for (const [current, segment] of transcript.segments.entries()) {
    const start = transcript.text.indexOf(segment.text, cursor);
    if (start < 0) return joinedText(transcript.segments.map((item, position) => position === index ? { ...item, text } : item));
    const end = start + segment.text.length;
    if (current === index) target = [start, end];
    cursor = end;
  }
  return target ? transcript.text.slice(0, target[0]) + text + transcript.text.slice(target[1]) : transcript.text;
}

function alignedWords(segment: Segment): AlignedWord[] | null {
  if (!segment.words?.length) return null;
  const aligned: AlignedWord[] = [];
  let cursor = 0;
  for (const word of segment.words) {
    const start = segment.text.indexOf(word.text, cursor);
    if (start < 0 || !word.text) return null;
    const end = start + word.text.length;
    aligned.push({ start, end, word });
    cursor = end;
  }
  return aligned;
}

function expandToWords(segment: Segment, start: number, end: number): [number, number] {
  for (const part of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(segment.text)) {
    const graphemeEnd = part.index + part.segment.length;
    if (part.index < start && start < graphemeEnd) start = part.index;
    if (part.index < end && end < graphemeEnd) end = graphemeEnd;
  }
  const aligned = alignedWords(segment);
  if (aligned) {
    for (const word of aligned) {
      if (word.start < start && start < word.end) start = word.start;
      if (word.start < end && end < word.end) end = word.end;
    }
    return [start, end];
  }
  const boundaries = new Intl.Segmenter(undefined, { granularity: "word" }).segment(segment.text);
  for (const part of boundaries) {
    if (!part.isWordLike) continue;
    const wordEnd = part.index + part.segment.length;
    if (part.index < start && start < wordEnd) start = part.index;
    if (part.index < end && end < wordEnd) end = wordEnd;
  }
  return [start, end];
}

function normalizedRanges(transcript: Transcript, selection: TranscriptSelectionRange[]): Map<number, [number, number][]> {
  const bySegment = new Map<number, [number, number][]>();
  for (const range of selection) {
    const segment = segmentAt(transcript, range.segment);
    if (!Number.isInteger(range.start) || !Number.isInteger(range.end)
      || range.start < 0 || range.end > segment.text.length || range.start > range.end) {
      throw new RangeError("Selección fuera de rango");
    }
    if (range.start === range.end) continue;
    const expanded = expandToWords(segment, range.start, range.end);
    bySegment.set(range.segment, [...(bySegment.get(range.segment) ?? []), expanded]);
  }
  for (const [index, ranges] of bySegment) {
    ranges.sort((a, b) => a[0] - b[0]);
    const merged: [number, number][] = [];
    for (const [start, end] of ranges) {
      const previous = merged.at(-1);
      if (previous && start <= previous[1]) previous[1] = Math.max(previous[1], end);
      else merged.push([start, end]);
    }
    bySegment.set(index, merged);
  }
  return bySegment;
}

function fragment(segment: Segment, start: number, end: number, speaker: string | null | undefined, personId?: string): Segment {
  const text = segment.text.slice(start, end);
  const chosenSpeaker = speaker === undefined ? {} : { speaker };
  const { personId: _personId, ...withoutPerson } = segment;
  const chosenPerson = personId ? { personId } : {};
  const aligned = alignedWords(segment);
  const words = aligned?.filter((item) => item.start >= start && item.end <= end).map((item) => ({ ...item.word }));
  if (words?.length) {
    return { ...withoutPerson, text, ...chosenSpeaker, ...chosenPerson, start: words[0].start, end: words.at(-1)!.end, words };
  }
  const { words: _words, ...rest } = withoutPerson;
  return { ...rest, text, ...chosenSpeaker, ...chosenPerson, timingShared: true };
}

function assignedSegment(segment: Segment, speaker: string, personId?: string): Segment {
  const { personId: _personId, ...rest } = cloneSegment(segment);
  return { ...rest, speaker, ...(personId ? { personId } : {}) };
}

export function assignSelectedSpeaker(transcript: Transcript, selection: TranscriptSelectionRange[], speaker: string, personId?: string): Transcript {
  if (!speaker.trim()) throw new RangeError("El hablante no puede estar vacío");
  const ranges = normalizedRanges(transcript, selection);
  if (!ranges.size) return { ...transcript, segments: transcript.segments.map(cloneSegment), recognitions: transcript.recognitions?.map((item) => ({ ...item })) };
  const affected = new Set<string>();
  let changed = false;
  const groups = transcript.segments.map((segment, index) => {
    const selected = ranges.get(index);
    if (!selected?.length) return [cloneSegment(segment)];
    if (segment.speaker === speaker && (segment.personId ?? undefined) === personId) return [cloneSegment(segment)];
    changed = true;
    if (segment.speaker && segment.speaker !== speaker) affected.add(segment.speaker);
    if (selected.length === 1 && selected[0][0] === 0 && selected[0][1] === segment.text.length) {
      return [assignedSegment(segment, speaker, personId)];
    }
    const pieces: Segment[] = [];
    let cursor = 0;
    for (const [start, end] of selected) {
      if (cursor < start) pieces.push(fragment(segment, cursor, start, segment.speaker, segment.personId ?? undefined));
      pieces.push(fragment(segment, start, end, speaker, personId));
      cursor = end;
    }
    if (cursor < segment.text.length) pieces.push(fragment(segment, cursor, segment.text.length, segment.speaker, segment.personId ?? undefined));
    return pieces;
  });
  const recognitions = transcript.recognitions?.filter((item) =>
    !changed || (!affected.has(item.speaker) && !affected.has(item.person) && item.speaker !== speaker && item.person !== speaker),
  ).map((item) => ({ ...item }));
  return { ...transcript, segments: groups.flat(), ...(recognitions ? { recognitions } : {}) };
}

export function changeSegmentText(transcript: Transcript, index: number, text: string): Transcript {
  segmentAt(transcript, index);
  const segments = transcript.segments.map((segment, current) => {
    if (current !== index) return cloneSegment(segment);
    const { words: _words, ...rest } = segment;
    return { ...rest, text, timingShared: true };
  });
  return { ...transcript, text: replacementText(transcript, index, text), segments, ...(transcript.recognitions ? { recognitions: transcript.recognitions.map((item) => ({ ...item })) } : {}) };
}

export function renameSpeaker(transcript: Transcript, from: string, to: string, personId?: string): Transcript {
  if (!to.trim()) throw new RangeError("El hablante no puede estar vacío");
  const segments = transcript.segments.map((segment) => segment.speaker === from ? assignedSegment(segment, to, personId) : cloneSegment(segment));
  const changed = transcript.segments.some((segment) => segment.speaker === from && (from !== to || (segment.personId ?? undefined) !== personId));
  const recognitions = transcript.recognitions?.filter((item) => !changed || (item.speaker !== from && item.person !== from && item.speaker !== to && item.person !== to))
    .map((item) => ({ ...item }));
  return { ...transcript, segments, ...(recognitions ? { recognitions } : {}) };
}

export function transcriptWithSegments(transcript: Transcript): Transcript {
  if (transcript.segments.length || !transcript.text) return { ...transcript, segments: transcript.segments.map(cloneSegment) };
  return { ...transcript, segments: [{ start: 0, end: transcript.duration ?? 0, text: transcript.text, timingShared: true }] };
}
