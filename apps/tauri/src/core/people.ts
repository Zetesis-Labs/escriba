import type { Transcript } from "../types";

export const personName = (value: string, current?: string) => {
  const name = value.trim();
  return name && name !== current ? name : null;
};

export const voiceCount = (count: number) => (count === 1 ? "1 huella" : `${count} huellas`);

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
