import type { RecordingPart } from "../types";
import { durationClock } from "./presentation";

export interface Piece {
  readonly id: string;
  readonly title: string;
  readonly createdAt: string;
  readonly audioPath: string | null;
  readonly status: string;
}

export interface MeasuredCombination {
  readonly duration: number;
  readonly parts: readonly { readonly start: number; readonly end: number }[];
}

export interface CombinedRecord {
  readonly title: string;
  readonly createdAt: string;
  readonly source: string;
  readonly duration: number;
  readonly parts: RecordingPart[];
}

export const combinedTitle = "Grabación combinada";
export const combinedSource = "Combinación";

export function initialOrder<T extends Piece>(recordings: readonly T[]): T[] {
  return [...recordings].sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0));
}

export function moveWithin<T>(order: readonly T[], index: number, delta: 1 | -1): readonly T[] {
  const target = index + delta;
  if (index < 0 || index >= order.length || target < 0 || target >= order.length) return order;
  const next = [...order];
  [next[index], next[target]] = [next[target]!, next[index]!];
  return next;
}

export function combineBlocker(recordings: readonly Piece[], busy: (id: string) => boolean): string | null {
  if (recordings.length < 2) return "Elige al menos dos grabaciones";
  for (const recording of recordings) {
    if (recording.status === "discarded") return `«${recording.title}» está borrada de la biblioteca`;
    if (!recording.audioPath) return `«${recording.title}» no tiene copia de audio`;
    if (busy(recording.id)) return `«${recording.title}» tiene un trabajo en marcha`;
  }
  return null;
}

export function measuredCombination(value: unknown): MeasuredCombination {
  const object = value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  const parts = Array.isArray(object?.parts) ? object.parts : undefined;
  const seconds = (item: unknown) => (typeof item === "number" && Number.isFinite(item) && item >= 0 ? item : undefined);
  const duration = seconds(object?.duration);
  if (duration === undefined || !parts) throw Error("El host no devolvió la medida de la combinación");
  return {
    duration,
    parts: parts.map((part) => {
      const piece = part && typeof part === "object" ? (part as Record<string, unknown>) : {};
      const start = seconds(piece.start);
      const end = seconds(piece.end);
      if (start === undefined || end === undefined) throw Error("El host no devolvió la medida de la combinación");
      return { start, end };
    }),
  };
}

export function unreadableAudioMessage(error: unknown, pieces: readonly Piece[]): string | null {
  const detail = error instanceof Error ? error.message : String(error);
  const piece = pieces.find((candidate) => candidate.audioPath && detail.includes(candidate.audioPath));
  if (!piece || !piece.audioPath) return null;
  const extension = piece.audioPath.includes(".") ? piece.audioPath.slice(piece.audioPath.lastIndexOf(".")) : "";
  return `No se puede leer el audio de «${piece.title}»${extension ? ` (${extension})` : ""}`;
}

export function combinedRecord(pieces: readonly Piece[], measured: MeasuredCombination): CombinedRecord {
  if (measured.parts.length !== pieces.length) throw Error("El host no midió todas las piezas");
  let previousEnd = -1;
  const parts = pieces.map((piece, index) => {
    const { start, end } = measured.parts[index]!;
    if (!(start >= 0 && end >= start && start > previousEnd)) throw Error("Las piezas medidas no siguen el orden elegido");
    previousEnd = end;
    return { recordingId: piece.id, title: piece.title, start, end };
  });
  return { title: combinedTitle, createdAt: pieces[0]!.createdAt, source: combinedSource, duration: measured.duration, parts };
}

export function piecesLabel(parts: readonly RecordingPart[]): string[] {
  return parts.map((part) => `${part.title} · ${durationClock(part.start)} – ${durationClock(part.end)}`);
}
