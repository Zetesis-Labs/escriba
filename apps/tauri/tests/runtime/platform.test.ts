import { expect, test } from "vitest";
import { macOS } from "../../src/core/platform";
import {
  currentPlatform,
  defaultResolvers,
  defaultWhisperModel,
  folderBookmarkRequired,
  localSttTryProblem,
  missingLlm,
} from "../../src/runtime/platform";
import { linux } from "../core/platforms";

test("en el Mac los valores de serie traen Whisper y Apple Intelligence", () => {
  expect(defaultResolvers(macOS)).toEqual([
    { id: "local-stt", name: "Whisper · en este Mac", role: "stt", local: true, enabled: true, model: "openai_whisper-large-v3-v20240930" },
    { id: "local-llm", name: "Apple Intelligence", role: "llm", local: true, enabled: true },
  ]);
  expect(localSttTryProblem(macOS)).toBe("Whisper en este Mac no tiene prueba");
});

test("en Linux los valores de serie no traen LLM ni nombres del Mac", () => {
  expect(defaultResolvers(linux)).toEqual([
    { id: "local-stt", name: "Whisper · en este equipo", role: "stt", local: true, enabled: true, model: "large-v3-turbo" },
  ]);
  expect(localSttTryProblem(linux)).toBe("Whisper · en este equipo no tiene prueba");
});

test("sin LLM incluido, resumir sin elegir uno dice qué falta", () => {
  expect(missingLlm("local-llm", linux)).toBe("La receta no tiene un LLM elegido: elígelo en Recetas");
  expect(missingLlm("remoto", linux)).toBeNull();
  expect(missingLlm("local-llm", macOS)).toBeNull();
});

test("el Whisper de serie es el de cada sistema", () => {
  expect(defaultWhisperModel(macOS)).toBe("openai_whisper-large-v3-v20240930");
  expect(defaultWhisperModel(linux)).toBe("large-v3-turbo");
});

test("solo donde se autorizan carpetas hace falta la autorización guardada", () => {
  expect(folderBookmarkRequired(macOS)).toBe(true);
  expect(folderBookmarkRequired(linux)).toBe(false);
});

test("el controlador toma lo que Rust le pasa y, sin ello, la tabla de Rust de su sistema", () => {
  const passed = { ...linux, recipesIsolated: true };
  expect(currentPlatform({ ESCRIBA_PLATFORM: JSON.stringify(passed) }, "linux")).toEqual(passed);
  expect(currentPlatform({}, "linux")).toEqual(linux);
  expect(currentPlatform({}, "darwin")).toEqual(macOS);
});
