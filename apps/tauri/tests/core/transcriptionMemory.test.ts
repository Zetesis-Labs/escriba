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
