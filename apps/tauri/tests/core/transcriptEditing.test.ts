import { expect, test } from "vitest";
import { assignSelectedSpeaker, changeSegmentText, renameSpeaker, transcriptWithSegments } from "../../src/core/transcriptEditing";
import type { Transcript } from "../../src/types";

test("asigna solo una palabra de un segmento y conserva las marcas reales", () => {
  const input: Transcript = {
    text: "Hola, mundo cruel.",
    segments: [{ start: 0, end: 3, speaker: "S1", text: "Hola, mundo cruel.", words: [
      { start: 0, end: 0.6, text: "Hola," },
      { start: 0.8, end: 1.5, text: "mundo" },
      { start: 1.8, end: 2.8, text: "cruel." },
    ] }],
    recognitions: [{ speaker: "S1", person: "Luis", distance: 0.1 }],
  };
  const result = assignSelectedSpeaker(input, [{ segment: 0, start: 6, end: 11 }], "Ana");
  expect(result).toEqual({
    text: "Hola, mundo cruel.",
    segments: [
      { start: 0, end: 0.6, speaker: "S1", text: "Hola, ", words: [{ start: 0, end: 0.6, text: "Hola," }] },
      { start: 0.8, end: 1.5, speaker: "Ana", text: "mundo", words: [{ start: 0.8, end: 1.5, text: "mundo" }] },
      { start: 1.8, end: 2.8, speaker: "S1", text: " cruel.", words: [{ start: 1.8, end: 2.8, text: "cruel." }] },
    ],
    recognitions: [],
  });
  expect(input.segments).toHaveLength(1);
  expect(input.recognitions).toHaveLength(1);
});

test("edita texto y descarta palabras obsoletas sin alterar otros segmentos", () => {
  const input: Transcript = { text: "Hola. Adiós.", segments: [
    { start: 0, end: 1, text: "Hola.", words: [{ start: 0, end: 1, text: "Hola." }] },
    { start: 2, end: 3, text: "Adiós." },
  ] };
  expect(changeSegmentText(input, 0, "Buenas.")).toEqual({ text: "Buenas. Adiós.", segments: [
    { start: 0, end: 1, text: "Buenas.", timingShared: true },
    { start: 2, end: 3, text: "Adiós." },
  ] });
  expect(input.segments[0].words).toEqual([{ start: 0, end: 1, text: "Hola." }]);
});

test("renombra un hablante en toda la nota y quita su reconocimiento anterior", () => {
  const input: Transcript = { text: "uno dos", segments: [
    { start: 0, end: 1, text: "uno", speaker: "S1" },
    { start: 1, end: 2, text: "dos", speaker: "S1" },
  ], recognitions: [{ speaker: "S1", person: "Luis", distance: 0.1 }] };
  expect(renameSpeaker(input, "S1", "Ana")).toEqual({ text: "uno dos", segments: [
    { start: 0, end: 1, text: "uno", speaker: "Ana" },
    { start: 1, end: 2, text: "dos", speaker: "Ana" },
  ], recognitions: [] });
});

test("asigna una selección entre segmentos sin confundir texto repetido", () => {
  const input: Transcript = { text: "sí, sí.\nsí, sí.", segments: [
    { start: 0, end: 2, text: "sí, sí.", speaker: "S1" },
    { start: 2, end: 4, text: "sí, sí.", speaker: "S2" },
  ] };
  const result = assignSelectedSpeaker(input, [
    { segment: 0, start: 4, end: 7 },
    { segment: 1, start: 0, end: 2 },
  ], "Ana");
  expect(result.text).toBe("sí, sí.\nsí, sí.");
  expect(result.segments).toEqual([
    { start: 0, end: 2, text: "sí, ", speaker: "S1", timingShared: true },
    { start: 0, end: 2, text: "sí.", speaker: "Ana", timingShared: true },
    { start: 2, end: 4, text: "sí", speaker: "Ana", timingShared: true },
    { start: 2, end: 4, text: ", sí.", speaker: "S2", timingShared: true },
  ]);
  expect(input.segments).toHaveLength(2);
});

test("amplía una selección dentro de una palabra Unicode sin cortar grafemas", () => {
  const transcript: Transcript = { text: "mañana café ☕", segments: [{ start: 0, end: 5, text: "mañana café ☕", speaker: "S1" }] };
  const result = assignSelectedSpeaker(transcript, [{ segment: 0, start: 9, end: 10 }], "Ana");
  expect(result.segments.map(({ text, speaker }) => [text, speaker])).toEqual([
    ["mañana ", "S1"], ["café", "Ana"], [" ☕", "S1"],
  ]);
});

test("no divide un emoji compuesto ni un carácter de dos unidades UTF-16", () => {
  const transcript: Transcript = { text: "hola 👩‍💻 fin", segments: [{ start: 0, end: 4, text: "hola 👩‍💻 fin", speaker: "S1" }] };
  const result = assignSelectedSpeaker(transcript, [{ segment: 0, start: 6, end: 7 }], "Ana");
  expect(result.segments.map(({ text }) => text)).toEqual(["hola ", "👩‍💻", " fin"]);
});

test("selección vacía no cambia el texto y rango inválido falla", () => {
  const transcript: Transcript = { text: "hola", segments: [{ start: 0, end: 1, text: "hola" }] };
  expect(assignSelectedSpeaker(transcript, [{ segment: 0, start: 2, end: 2 }], "Ana")).toEqual(transcript);
  expect(() => assignSelectedSpeaker(transcript, [{ segment: 0, start: 0, end: 5 }], "Ana")).toThrow(RangeError);
  expect(() => assignSelectedSpeaker(transcript, [{ segment: 1, start: 0, end: 1 }], "Ana")).toThrow(RangeError);
});

test("convierte texto sin segmentos en una intervención editable", () => {
  const transcript: Transcript = { text: "hola mundo", segments: [], duration: 8 };
  expect(transcriptWithSegments(transcript)).toEqual({ text: "hola mundo", duration: 8, segments: [
    { start: 0, end: 8, text: "hola mundo", timingShared: true },
  ] });
  expect(transcript.segments).toEqual([]);
});

test("asignar una intervención completa conserva sus tiempos y palabras", () => {
  const transcript: Transcript = { text: "hola", segments: [{ start: 2, end: 4, text: "hola", speaker: "S1", words: [
    { start: 2.2, end: 3.8, text: "hola" },
  ] }] };
  expect(assignSelectedSpeaker(transcript, [{ segment: 0, start: 0, end: 4 }], "Ana").segments).toEqual([
    { start: 2, end: 4, text: "hola", speaker: "Ana", words: [{ start: 2.2, end: 3.8, text: "hola" }] },
  ]);
  expect(transcriptWithSegments({ text: "", segments: [] })).toEqual({ text: "", segments: [] });
});

test("editar texto repetido mantiene saltos y espacios originales", () => {
  const transcript: Transcript = { text: "eco\n\neco", segments: [
    { start: 0, end: 1, text: "eco" }, { start: 1, end: 2, text: "eco" },
  ] };
  expect(changeSegmentText(transcript, 1, "voz").text).toBe("eco\n\nvoz");
});

test("elegir una persona guarda su ID; elegir sólo etiqueta borra el ID previo", () => {
  const transcript: Transcript = { text: "hola adiós", segments: [
    { start: 0, end: 1, text: "hola", speaker: "Ana", personId: "person:old" },
    { start: 1, end: 2, text: "adiós", speaker: "Luis", personId: "person:luis" },
  ] };
  expect(renameSpeaker(transcript, "Ana", "Ana", "person:ana").segments[0]).toMatchObject({ speaker: "Ana", personId: "person:ana" });
  expect(renameSpeaker(transcript, "Ana", "Speaker 1").segments[0]).toEqual({ start: 0, end: 1, text: "hola", speaker: "Speaker 1" });
  expect(renameSpeaker(transcript, "Ana", "Speaker 1").segments[1].personId).toBe("person:luis");
});

test("dividir selección conserva la persona sólo en fragmentos no reasignados", () => {
  const transcript: Transcript = { text: "uno dos tres", segments: [{ start: 0, end: 3, text: "uno dos tres", speaker: "Ana", personId: "person:ana" }] };
  const changed = assignSelectedSpeaker(transcript, [{ segment: 0, start: 4, end: 7 }], "Luis", "person:luis");
  expect(changed.segments.map(({ text, speaker, personId }) => [text, speaker, personId])).toEqual([
    ["uno ", "Ana", "person:ana"], ["dos", "Luis", "person:luis"], [" tres", "Ana", "person:ana"],
  ]);
  expect(assignSelectedSpeaker(transcript, [{ segment: 0, start: 4, end: 7 }], "Speaker 2").segments[1].personId).toBeUndefined();
});
