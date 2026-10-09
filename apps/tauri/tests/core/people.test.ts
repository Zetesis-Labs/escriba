import { describe, expect, test } from "vitest";
import { canBeginVoiceSample, correctedSpeaker, forgottenRecognition, personName, speakerTitle, voiceCount } from "../../src/core/people";
import type { Transcript } from "../../src/types";

const recognized: Transcript = {
  text: "Hola. Adiós.",
  segments: [
    { start: 0, end: 1, speaker: "Speaker 1", text: "Hola." },
    { start: 1, end: 2, speaker: "Nuria", text: "Adiós." },
  ],
  recognitions: [{ speaker: "Speaker 2", person: "Nuria", distance: 0.2 }],
};

describe("Personas como en Swift", () => {
  test("solo un nombre no vacío distinto permite renombrar o juntar", () => {
    expect(personName(" Nuria \n", "Ana")).toBe("Nuria");
    expect(personName("  ", "Ana")).toBeNull();
    expect(personName(" Ana ", "Ana")).toBeNull();
  });

  test("la lista distingue una huella de varias", () => {
    expect(voiceCount(1)).toBe("1 huella");
    expect(voiceCount(2)).toBe("2 huellas");
  });

  test("el menú indica si el hablante se reconoció y la distancia", () => {
    expect(speakerTitle("Nuria", recognized)).toBe("Nuria · reconocido (0,20)");
    expect(speakerTitle("Speaker 1", recognized)).toBe("Speaker 1");
  });

  test("renombrar una voz reconocida enseña la etiqueta visible y borra su reconocimiento", () => {
    expect(correctedSpeaker(recognized, "Nuria", " Ana ")).toEqual({
      transcript: {
        ...recognized,
        segments: [recognized.segments[0], { ...recognized.segments[1], speaker: "Ana" }],
        recognitions: [],
      },
      teaching: { speaker: "Nuria", person: "Ana" },
    });
  });

  test("No es Nuria restaura Speaker 2 sin aprender ni quitar la persona", () => {
    expect(forgottenRecognition(recognized, "Nuria")).toEqual({
      ...recognized,
      segments: [recognized.segments[0], { ...recognized.segments[1], speaker: "Speaker 2" }],
      recognitions: [],
    });
  });

  test("fusionar solo enseña si la persona destino ya existe", () => {
    expect(correctedSpeaker(recognized, "Speaker 1", "Nuria", true)?.teaching).toEqual({
      speaker: "Speaker 1", person: "Nuria", existingOnly: true,
    });
  });

  test("fusionar borra también el reconocimiento del destino", () => {
    const transcript: Transcript = {
      text: "",
      segments: [
        { start: 0, end: 1, speaker: "Ana", text: "Uno" },
        { start: 1, end: 2, speaker: "Luis", text: "Dos" },
      ],
      recognitions: [
        { speaker: "Speaker 1", person: "Ana", distance: 0.1 },
        { speaker: "Speaker 2", person: "Luis", distance: 0.2 },
      ],
    };
    expect(correctedSpeaker(transcript, "Ana", "Luis", true)?.transcript.recognitions).toEqual([]);
  });

  test("elegir un audio o grabar exige nombre y una muestra inactiva o fallida", () => {
    expect(canBeginVoiceSample(" Ana ", "idle")).toBe(true);
    expect(canBeginVoiceSample("Ana", "failed")).toBe(true);
    expect(canBeginVoiceSample("  ", "idle")).toBe(false);
    expect(canBeginVoiceSample("Ana", "requesting")).toBe(false);
    expect(canBeginVoiceSample("Ana", "recording")).toBe(false);
    expect(canBeginVoiceSample("Ana", "analyzing")).toBe(false);
  });
});
