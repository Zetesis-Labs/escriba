import { isObject } from "./json";

// Each embedding model has its own scale: SpeakerKit's on the Mac and
// TitaNet's on Linux, calibrated with public real voices (docs/plan-linux.md, L5).
const THRESHOLDS: Record<string, number> = {
  "speakerkit/pyannote-v3/speaker_embedder": 0.3,
  "sherpa-onnx/nemo-titanet-small": 0.5,
};
export const matchThreshold = (model: string) => THRESHOLDS[model] ?? 0.3;
export interface SpeakerVoice {
  speaker: string;
  embedding: number[];
  model: string;
}
export interface KnownVoice {
  person: string;
  personId: string;
  embedding: number[];
  model: string;
}
export interface Recognition {
  speaker: string;
  person: string;
  personId: string;
  distance: number;
}
export interface SpeakerSpan {
  speaker: string;
  start: number;
  end: number;
}
function hasEmbedding(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(hasEmbedding);
  if (isObject(value)) return Object.entries(value).some(([key, item]) => key.toLowerCase().includes("embedding") || hasEmbedding(item));
  return false;
}
export function publicReply<T>(value: T): T {
  if (hasEmbedding(value)) throw Error("La respuesta incluye una huella de voz privada");
  return value;
}
export function cosineDistance(a: number[], b: number[]): number | undefined {
  if (!a.length || a.length !== b.length) return undefined;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let index = 0; index < a.length; index++) {
    dot += a[index]! * b[index]!;
    normA += a[index]! * a[index]!;
    normB += b[index]! * b[index]!;
  }
  if (!Number.isFinite(dot) || !Number.isFinite(normA) || !Number.isFinite(normB) || normA <= 0 || normB <= 0) return undefined;
  return Math.min(Math.max(1 - dot / (Math.sqrt(normA) * Math.sqrt(normB)), 0), 2);
}
export function validVoice(voice: unknown): voice is SpeakerVoice {
  return (
    isObject(voice) &&
    typeof voice.speaker === "string" &&
    typeof voice.model === "string" &&
    Array.isArray(voice.embedding) &&
    voice.embedding.every((value) => typeof value === "number")
  );
}
export function recognize(voices: SpeakerVoice[], known: KnownVoice[]): Recognition[] {
  const candidates: Recognition[] = [];
  const speakers = new Set<string>();
  for (const voice of voices) {
    if (speakers.has(voice.speaker)) continue;
    speakers.add(voice.speaker);
    const people = new Set<string>();
    for (const person of known) {
      if (people.has(person.person)) continue;
      people.add(person.person);
      let nearest: number | undefined;
      let threshold = 0;
      for (const own of voices.filter((item) => item.speaker === voice.speaker))
        for (const candidate of known.filter((item) => item.person === person.person && item.model === own.model)) {
          const distance = cosineDistance(own.embedding, candidate.embedding);
          if (distance !== undefined && (nearest === undefined || distance < nearest)) {
            nearest = distance;
            threshold = matchThreshold(own.model);
          }
        }
      if (nearest !== undefined && nearest <= threshold)
        candidates.push({ speaker: voice.speaker, person: person.person, personId: person.personId, distance: nearest });
    }
  }
  candidates.sort((left, right) => left.distance - right.distance);
  const usedSpeakers = new Set<string>();
  const usedPeople = new Set<string>();
  return candidates.filter((candidate) => {
    if (usedSpeakers.has(candidate.speaker) || usedPeople.has(candidate.person)) return false;
    usedSpeakers.add(candidate.speaker);
    usedPeople.add(candidate.person);
    return true;
  });
}
export function speechBySpeaker(spans: SpeakerSpan[]): Map<string, number> {
  const speech = new Map<string, number>();
  for (const span of spans) speech.set(span.speaker, (speech.get(span.speaker) ?? 0) + span.end - span.start);
  return speech;
}
export function dominantVoice(voices: SpeakerVoice[], spans: SpeakerSpan[], minimumSpeech: number): SpeakerVoice | undefined {
  let best: [string, number] | undefined;
  for (const [speaker, seconds] of speechBySpeaker(spans)) if (!best || seconds > best[1]) best = [speaker, seconds];
  if (!best || best[1] < minimumSpeech) return undefined;
  return voices.find((voice) => voice.speaker === best![0]);
}
