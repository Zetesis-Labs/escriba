import { test } from "vitest";
import assert from "node:assert/strict";
import { cosineDistance, dominantVoice, publicReply, recognize, speechBySpeaker, type KnownVoice, type SpeakerVoice } from "../../../src/runtime/library/voices";

const voice = (speaker: string, embedding: number[], model: string): SpeakerVoice => ({ speaker, embedding, model });
const known = (person: string, embedding: number[], model: string): KnownVoice => ({ personId: person, person, embedding, model });

test("coseno mide dirección y descarta huellas inválidas", () => {
  assert.equal(cosineDistance([1, 0], [2, 0]), 0);
  assert.equal(cosineDistance([1, 0], [-1, 0]), 2);
  assert.equal(cosineDistance([1, 0], [0, 1]), 1);
  assert.equal(cosineDistance([1], [1, 0]), undefined);
  assert.equal(cosineDistance([0, 0], [1, 0]), undefined);
});

test("reconoce por modelo y umbral con asignación uno a uno", () => {
  const found = recognize(
    [voice("Speaker 1", [1, 0.2], "m"), voice("Speaker 2", [1, 0.05], "m"), voice("Speaker 3", [0, 1], "otro")],
    [known("Rubén", [1, 0], "m"), known("Nuria", [0, 1], "m")],
  );
  assert.equal(found.length, 1);
  assert.equal(found[0]!.speaker, "Speaker 2");
  assert.equal(found[0]!.person, "Rubén");
  assert.ok(found[0]!.distance < 0.01);
});

test("reconoce la huella más cercana entre varias de cada persona", () => {
  const found = recognize(
    [voice("Speaker 1", [0.01, 1], "m"), voice("Speaker 1", [1, 0], "m"), voice("Speaker 2", [0, 1], "m")],
    [known("Rubén", [1, 0.01], "m"), known("Nuria", [0, 1], "m")],
  );
  assert.deepEqual(found.map((item) => [item.speaker, item.person]), [["Speaker 2", "Nuria"], ["Speaker 1", "Rubén"]]);
});

test("la muestra elige la voz que habla al menos treinta segundos", () => {
  const voices = [voice("S1", [1, 0], "m"), voice("S2", [0, 1], "m")];
  const spans = [{ speaker: "S1", start: 0, end: 15 }, { speaker: "S2", start: 15, end: 46 }, { speaker: "S1", start: 46, end: 47 }];
  assert.equal(speechBySpeaker(spans).get("S1"), 16);
  assert.deepEqual(dominantVoice(voices, spans, 30), voices[1]);
  assert.equal(dominantVoice(voices, spans, 32), undefined);
});

test("ninguna respuesta pública contiene embedding ni revela su valor en el error", () => {
  assert.throws(() => publicReply({ recording: { segments: [{ voiceEmbedding: [0.123456] }] } }), (error: Error) => !error.message.includes("0.123456"));
  assert.equal((publicReply({ recognitions: [{ person: "Rubén", distance: 0.1 }] }).recognitions[0] as { person: string }).person, "Rubén");
});
