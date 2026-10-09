import type { Segment, Transcript } from "../types";
import { speakers } from "./presentation";

const quoted = (text: string) => JSON.stringify(text);
const number = (value: number) => (!Number.isFinite(value) ? "0" : Number.isInteger(value) && Math.abs(value) < 1e15 ? String(value) : String(value));
const iso8601 = (date: Date) => date.toISOString().replace(/\.\d{3}Z$/, "Z");

function segmentJSON(segment: Segment) {
  const parts = [`"start": ${number(segment.start)}`, `"end": ${number(segment.end)}`];
  if (segment.speaker) parts.push(`"speaker": ${quoted(segment.speaker)}`);
  parts.push(`"text": ${quoted(segment.text)}`);
  if (segment.words?.length)
    parts.push(`"words": [${segment.words.map((word) => `[${number(word.start)}, ${number(word.end)}, ${quoted(word.text)}]`).join(", ")}]`);
  return `{${parts.join(", ")}}`;
}

export function transcriptExportJSON(input: { key: string; startedAt: Date; source: string; backend?: string; transcript: Transcript }) {
  const { transcript } = input;
  const duration = transcript.segments.at(-1)?.end;
  const text = transcript.segments.length ? transcript.segments.map((segment) => segment.text).join("\n") : transcript.text;
  const fields = [`"version": 1`, `"key": ${quoted(input.key)}`, `"startedAt": ${quoted(iso8601(input.startedAt))}`, `"source": ${quoted(input.source)}`];
  if (input.backend) fields.push(`"backend": ${quoted(input.backend)}`);
  if (duration !== undefined) fields.push(`"duration": ${number(duration)}`);
  fields.push(`"speakers": [${speakers(transcript).map(quoted).join(", ")}]`);
  fields.push(`"text": ${quoted(text)}`);
  if (transcript.segments.length) {
    fields.push(`"wordFormat": ["start", "end", "text"]`);
    fields.push(`"segments": [\n${transcript.segments.map((segment) => `    ${segmentJSON(segment)}`).join(",\n")}\n  ]`);
  }
  return `{\n${fields.map((field) => `  ${field}`).join(",\n")}\n}`;
}
