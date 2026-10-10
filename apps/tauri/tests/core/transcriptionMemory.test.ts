import { expect, test } from "vitest";
import { reusableTranscription } from "../../src/core/transcriptionMemory";

test("una transcripción diarizada solo se recupera cuando conserva sus huellas", () => {
  const inputs = { backend: "local-stt", diarize: true, model: "whisper" };
  expect(reusableTranscription({ inputs, hasVoices: false }, inputs)).toBe(false);
  expect(reusableTranscription({ inputs }, inputs)).toBe(false);
  expect(reusableTranscription({ inputs, hasVoices: true }, inputs)).toBe(true);
});

test("sin diarización se recupera por los mismos criterios, aunque cambie el orden de las claves", () => {
  const version = { inputs: { backend: "local-stt", diarize: false, model: "whisper" } };
  expect(reusableTranscription(version, { model: "whisper", diarize: false, backend: "local-stt" })).toBe(true);
  expect(reusableTranscription(version, { model: "otro", diarize: false, backend: "local-stt" })).toBe(false);
});

test("una versión Swift traducida coincide con los criterios actuales solo si conserva la huella y las voces", () => {
  const inputs = {
    audioHash: "hash-de-copia",
    backend: "local-stt",
    model: "openai_whisper-large-v3-v20240930",
    language: "es",
    diarize: false,
    speakers: null,
  };
  expect(reusableTranscription({ inputs }, { ...inputs })).toBe(true);
  expect(reusableTranscription({ inputs }, { ...inputs, audioHash: "otro-audio" })).toBe(false);
  const diarized = { ...inputs, diarize: true, speakers: 2 };
  expect(reusableTranscription({ inputs: diarized, hasVoices: false }, diarized)).toBe(false);
  expect(reusableTranscription({ inputs: diarized, hasVoices: true }, diarized)).toBe(true);
});
