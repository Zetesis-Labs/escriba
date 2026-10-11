import type { Person, Transcript, VoiceRegistration } from "../types";

export const personName = (value: string, current?: string) => {
  const name = value.trim();
  return name && name !== current ? name : null;
};

export const voiceCount = (count: number) => (count === 1 ? "1 huella" : `${count} huellas`);

export const canBeginVoiceSample = (name: string, state: VoiceRegistration["state"]) =>
  Boolean(name.trim()) && (state === "idle" || state === "failed");

export function speakerTitle(speaker: string, transcript: Transcript) {
  const recognition = transcript.recognitions?.find((item) => item.person === speaker);
  return recognition ? `${speaker} · reconocido (${recognition.distance.toLocaleString("es-ES", { minimumFractionDigits: 2, maximumFractionDigits: 2 })})` : speaker;
}

export function correctedSpeaker(transcript: Transcript, visibleSpeaker: string, wanted: string, existingOnly = false) {
  const person = personName(wanted, visibleSpeaker);
  if (!person) return null;
  return {
    transcript: {
      ...transcript,
      segments: transcript.segments.map((segment) => (segment.speaker === visibleSpeaker ? { ...segment, speaker: person } : segment)),
      recognitions: transcript.recognitions?.filter((item) => item.person !== visibleSpeaker && item.person !== person),
    },
    teaching: { speaker: visibleSpeaker, person, ...(existingOnly ? { existingOnly: true } : {}) },
  };
}

export function forgottenRecognition(transcript: Transcript, visibleSpeaker: string) {
  const recognition = transcript.recognitions?.find((item) => item.person === visibleSpeaker);
  if (!recognition) return null;
  return {
    ...transcript,
    segments: transcript.segments.map((segment) =>
      segment.speaker === visibleSpeaker ? { ...segment, speaker: recognition.speaker } : segment,
    ),
    recognitions: transcript.recognitions?.filter((item) => item !== recognition),
  };
}

const speakerPalette = ["#3178c6", "#a05bc7", "#c65b37", "#31806b", "#b74e78", "#82723a", "#5763be", "#397f96"];

export function personColor(name: string | null | undefined, people: readonly Person[] = []) {
  if (!name) return "#8e8e93";
  const saved = people.find((person) => person.name === name)?.color;
  if (saved && /^#[0-9a-f]{6}$/i.test(saved)) return saved;
  let hash = 0;
  for (const character of name) hash = (Math.imul(hash, 31) + character.codePointAt(0)!) >>> 0;
  return speakerPalette[hash % speakerPalette.length];
}

export const personColors = (names: readonly string[], people: readonly Person[]) =>
  Object.fromEntries([...new Set([...names, ...people.map((person) => person.name)])].map((name) => [name, personColor(name, people)]));
