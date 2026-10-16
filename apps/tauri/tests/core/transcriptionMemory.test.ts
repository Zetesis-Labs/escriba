import { expect, test } from "vitest";
import { normalizeTranscriptionInputs, reusableTranscription, transcriptionCriteriaKey, withCorrectionCriteria } from "../../src/core/transcriptionMemory";

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

test("sin diarización el número guardado no cambia los criterios ni el audio solicitado", () => {
  const saved = { audioHash: "hash", backend: "local-stt", diarize: false, speakers: 2 };
  const normalized = normalizeTranscriptionInputs(saved);
  expect(normalized).toEqual({ ...saved, speakers: null });
  expect(saved.speakers).toBe(2);
  expect(transcriptionCriteriaKey(saved)).toBe(transcriptionCriteriaKey({ ...saved, speakers: null }));
  expect(reusableTranscription({ inputs: saved }, { ...saved, speakers: null })).toBe(true);
  expect(normalizeTranscriptionInputs({ ...saved, diarize: true })).toEqual({ ...saved, diarize: true });
});

test("una corrección guardada sin criterios toma los de la última versión no corregida anterior", () => {
  const plain = { backend: "local-stt", diarize: false };
  const diarized = { backend: "local-stt", diarize: true };
  const versions = withCorrectionCriteria([
    { backend: "local-stt", inputs: plain },
    { backend: "correccion" },
    { backend: "local-stt", inputs: diarized },
    { backend: "manual" },
    { backend: "correccion", inputs: plain },
  ]);
  expect(versions.map((version) => version.inputs)).toEqual([plain, plain, diarized, diarized, plain]);
  expect(withCorrectionCriteria([{ backend: "correccion" }])).toEqual([{ backend: "correccion" }]);
});
