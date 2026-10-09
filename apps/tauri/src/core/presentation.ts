import type { Digest, Recording, Segment, Transcript } from "../types";

const monthNames = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
];
const shortMonthNames = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"];

export const noteTitleLimit = 80;
export const noteDescriptionLimit = 200;

const two = (value: number) => String(value).padStart(2, "0");

export function clockStamp(seconds: number) {
  const whole = Math.floor(Math.max(seconds, 0));
  return `${Math.floor(whole / 60)}:${two(whole % 60)}`;
}

export function durationClock(seconds: number) {
  const total = Math.floor(Math.max(seconds, 0));
  const body = `${two(Math.floor((total % 3600) / 60))}:${two(total % 60)}`;
  return total >= 3600 ? `${Math.floor(total / 3600)}:${body}` : body;
}

interface Parts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

export function dateParts(date: Date, timeZone?: string): Parts {
  const formatted = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    hourCycle: "h23",
  }).formatToParts(date);
  const value = (type: string) => Number(formatted.find((part) => part.type === type)?.value ?? 0);
  return { year: value("year"), month: value("month"), day: value("day"), hour: value("hour"), minute: value("minute") };
}

export function longDate(date: Date, timeZone?: string) {
  const parts = dateParts(date, timeZone);
  const month = monthNames[Math.max(0, Math.min(11, parts.month - 1))];
  return `${parts.day} de ${month} de ${parts.year}, ${two(parts.hour)}:${two(parts.minute)}`;
}

const sameDay = (a: Parts, b: Parts) => a.year === b.year && a.month === b.month && a.day === b.day;

export function recordingWhen(date: Date, now: Date, timeZone?: string) {
  const parts = dateParts(date, timeZone);
  const today = dateParts(now, timeZone);
  const yesterday = dateParts(new Date(now.getTime() - 86_400_000), timeZone);
  const time = `${two(parts.hour)}:${two(parts.minute)}`;
  if (sameDay(parts, today)) return `hoy, ${time}`;
  if (sameDay(parts, yesterday)) return `ayer, ${time}`;
  const month = shortMonthNames[parts.month - 1];
  return parts.year === today.year ? `${parts.day} ${month}, ${time}` : `${parts.day} ${month} ${parts.year}`;
}

export function noteTitle(digest: Digest | null | undefined, key: string, text: string, limit = noteTitleLimit) {
  if (digest?.title) return digest.title;
  const words = text.split(/\s+/).filter(Boolean);
  if (!words.length) return key;
  let length = 0;
  const taken: string[] = [];
  for (const word of words) {
    const next = taken.length ? length + 1 + [...word].length : [...word].length;
    if (next > limit) break;
    length = next;
    taken.push(word);
  }
  const head = taken.join(" ");
  return taken.length < words.length ? `${head}…` : head;
}

function firstSentence(line: string) {
  for (let index = 0; index < line.length; index++) {
    const next = line[index + 1];
    if (".?!".includes(line[index]) && (next === undefined || /\s/.test(next))) return line.slice(0, index + 1);
  }
  return line;
}

export function noteDescription(summary: string | null | undefined) {
  const trimmed = summary?.trim();
  if (!trimmed) return null;
  const line = trimmed.split(/\r?\n/)[0] ?? trimmed;
  const sentence = firstSentence(line);
  if ([...sentence].length <= noteDescriptionLimit) return sentence;
  let taken = "";
  for (const word of sentence.split(/\s+/).filter(Boolean)) {
    const next = taken ? `${taken} ${word}` : word;
    if ([...next].length >= noteDescriptionLimit) break;
    taken = next;
  }
  return `${taken || [...sentence].slice(0, noteDescriptionLimit - 1).join("")}…`;
}

export function recordingTitle(digest: Digest | null | undefined, preview: string | null | undefined, startedAt: Date, timeZone?: string) {
  const text = preview?.trim() ?? "";
  if (digest?.title || text) return noteTitle(digest, "", text, 60);
  return `Grabación del ${longDate(startedAt, timeZone)}`;
}

export function recordingExcerpt(digest: Digest | null | undefined, preview: string | null | undefined) {
  const summary = noteDescription(digest?.summary);
  if (summary) return summary;
  const flat = preview?.split(/\r?\n/).join(" ").trim();
  return flat ? flat : null;
}

export function visibleTags(tags: string[], limit = 3) {
  return { shown: tags.slice(0, limit), hidden: Math.max(tags.length - limit, 0) };
}

export function librarySummary(statuses: Recording["status"][]) {
  const pending = statuses.filter((status) => status !== "done").length;
  const total = `${statuses.length} en la biblioteca`;
  return pending === 0 ? total : `${total}, ${pending} sin transcribir`;
}

export function speakerBefore(segments: Segment[], index: number) {
  if (index <= 0 || index > segments.length) return null;
  return segments[index - 1].speaker ?? null;
}

export function startsNewSpeaker(segments: Segment[], index: number) {
  if (index < 0 || index >= segments.length) return false;
  return (segments[index].speaker ?? null) !== speakerBefore(segments, index);
}

export function speakers(transcript: Transcript) {
  const seen = new Set<string>();
  for (const segment of transcript.segments) if (segment.speaker) seen.add(segment.speaker);
  return [...seen];
}

export interface PlaybackPosition {
  segment: number;
  word: number | null;
}

function lastIndex<T>(items: T[], match: (item: T) => boolean) {
  for (let index = items.length - 1; index >= 0; index--) if (match(items[index])) return index;
  return -1;
}

export function playbackPosition(transcript: Transcript, time: number): PlaybackPosition | null {
  const segment = lastIndex(transcript.segments, (item) => item.start <= time);
  if (segment < 0) return null;
  const word = lastIndex(transcript.segments[segment].words ?? [], (item) => item.start <= time);
  return { segment, word: word < 0 ? null : word };
}

export function renderedTranscript(transcript: Transcript) {
  if (!speakers(transcript).length) return transcript.text;
  const turns: { speaker: string | null; text: string[] }[] = [];
  for (const segment of transcript.segments) {
    const speaker = segment.speaker ?? null;
    const last = turns.at(-1);
    if (last && last.speaker === speaker) last.text.push(segment.text);
    else turns.push({ speaker, text: [segment.text] });
  }
  return turns.map((turn) => (turn.speaker ? `${turn.speaker}: ${turn.text.join(" ")}` : turn.text.join(" "))).join("\n");
}

export const rowActionText = {
  removeAudio: (originalExists: boolean) =>
    originalExists
      ? "Se borra la copia de la biblioteca; el original en su carpeta se conserva y las transcripciones se quedan."
      : "El original ya no existe: sin la copia, el audio se pierde del todo. Las transcripciones se quedan.",
  unpublish: (provider: string) =>
    provider === "notion"
      ? "La página se archiva en Notion (se puede restaurar desde su papelera). La grabación y sus transcripciones se quedan en la biblioteca."
      : "Se borran sus ficheros .md de la carpeta del bundle y se anota la baja en el registro. La grabación y sus transcripciones se quedan en la biblioteca.",
  discard:
    "Desaparecen la fila, sus transcripciones y la copia de audio. El fichero original en su carpeta no se toca, pero la grabacion no volvera a aparecer en la biblioteca.",
};
