import { expect, test } from "vitest";
import { defaultResolvers, localSttTryProblem } from "../../src/runtime/platform";

test("en el Mac los valores de serie traen Whisper y Apple Intelligence", () => {
  expect(defaultResolvers("darwin")).toEqual([
    { id: "local-stt", name: "Whisper · en este Mac", role: "stt", local: true, enabled: true, model: "openai_whisper-large-v3-v20240930" },
    { id: "local-llm", name: "Apple Intelligence", role: "llm", local: true, enabled: true },
  ]);
  expect(localSttTryProblem("darwin")).toBe("Whisper en este Mac no tiene prueba");
});

test("en Linux los valores de serie no traen LLM ni nombres del Mac", () => {
  expect(defaultResolvers("linux")).toEqual([
    { id: "local-stt", name: "Whisper · en este equipo", role: "stt", local: true, enabled: true, model: "openai_whisper-large-v3-v20240930" },
  ]);
  expect(localSttTryProblem("linux")).toBe("Whisper · en este equipo no tiene prueba");
});
