import { describe, expect, test } from "vitest";
import { notificationProblems } from "../../src/core/notificationProblems";
import type { NativeStatus } from "../../src/types";
import type { RuntimeContext } from "../../src/runtime/contracts";

const localStt = { id: "local-stt", name: "Whisper en este Mac", role: "stt" as const, local: true, enabled: true };
const localLlm = { id: "local-llm", name: "Apple Intelligence", role: "llm" as const, local: true, enabled: true };
const context: RuntimeContext = {
  recordings: [], accounts: [], destinations: [],
  settings: { defaultRecipeId: "default", language: "es", whisperModel: "large-v3" },
  resolvers: [localStt, localLlm],
  recipes: [{ id: "default", name: "Por defecto", kind: "form", values: {} }],
};
const status: NativeStatus = { protocolVersion: 1, whisper: { available: false }, llm: { available: false, reason: "el modelo del sistema aún se está descargando" } };

describe("problemas al arrancar los resolutores de la receta por defecto", () => {
  test("avisa de ambos motores locales cuando la receta resume", () => {
    expect(notificationProblems(context, status)).toEqual([
      { role: "stt", name: "Whisper en este Mac", reason: "el modelo de Whisper no está descargado; descárgalo aquí abajo" },
      { role: "llm", name: "Apple Intelligence", reason: "el modelo del sistema aún se está descargando" },
    ]);
  });

  test("si la receta no resume solo avisa del STT seleccionado", () => {
    const remote = { id: "remote-stt", name: "Groq", role: "stt" as const, local: false, enabled: true, url: "https://api.groq.com/openai/v1", model: "" };
    expect(notificationProblems({
      ...context,
      resolvers: [...context.resolvers, remote],
      recipes: [{ ...context.recipes[0], values: { stt: "remote-stt", resumir: null } }],
    }, status)).toEqual([{ role: "stt", name: "Groq", reason: "Elige el modelo." }]);
  });

  test("recetas de código o con base usan los motores locales estándar", () => {
    for (const recipe of [
      { id: "default", name: "Código", kind: "code" as const, values: { stt: "remote-stt", resumir: false } },
      { id: "default", name: "Derivada", kind: "form" as const, base: "base", values: { stt: "remote-stt", resumir: false } },
    ]) {
      expect(notificationProblems({ ...context, recipes: [recipe] }, status).map(({ role }) => role)).toEqual(["stt", "llm"]);
    }
  });

  test("no avisa de resolutores remotos válidos ni consulta su credencial", () => {
    const stt = { id: "remote-stt", name: "Groq", role: "stt" as const, local: false, enabled: true, url: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", hasCredential: false };
    const llm = { id: "remote-llm", name: "OpenAI", role: "llm" as const, local: false, enabled: true, url: "https://api.openai.com/v1", model: "gpt-4o-mini", hasCredential: false };
    expect(notificationProblems({
      ...context,
      resolvers: [...context.resolvers, stt, llm],
      recipes: [{ ...context.recipes[0], values: { stt: stt.id, llm: llm.id } }],
    }, status)).toEqual([]);
  });
});
