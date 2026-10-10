import { test } from "vitest";
import assert from "node:assert/strict";
import { manualSummaryReading, manualSummaryResolver } from "../../src/core/manualSummary";
import type { Recipe, Resolver } from "../../src/types";

const form: Recipe = { id: "actual", name: "Actual", kind: "form", values: {} };

test("el formulario por defecto aporta LLM, idioma y prompt para resumir a mano", () => {
  assert.deepEqual(manualSummaryReading("actual", [
    { ...form, values: { llm: "remote-llm", idioma: "eu", prompt: "Tres frases", resumir: false } },
  ]), { llm: "remote-llm", language: "eu", prompt: "Tres frases" });
});

test("sin valores propios se usan los de serie de Swift", () => {
  assert.deepEqual(manualSummaryReading("actual", [form]), { llm: undefined, language: "es", prompt: undefined });
  assert.deepEqual(manualSummaryReading("no-existe", [form]), { llm: undefined, language: "es", prompt: undefined });
});

test("código y formulario con base no aportan sus valores al resumen manual", () => {
  for (const recipe of [
    { ...form, kind: "code" as const, values: { llm: "remote-llm", idioma: "en", prompt: "Ignorar" } },
    { ...form, base: "base", values: { llm: "remote-llm", idioma: "en", prompt: "Ignorar" } },
  ]) {
    assert.deepEqual(manualSummaryReading("actual", [recipe]), { llm: undefined, language: "es", prompt: undefined });
  }
});

test("idioma automático equivale a nulo y los valores no textuales no sustituyen la lectura", () => {
  assert.deepEqual(manualSummaryReading("actual", [{ ...form, values: { idioma: null, llm: 42, prompt: false } }]), {
    llm: undefined, language: null, prompt: undefined,
  });
});

test("el LLM explícito prevalece sobre el guardado si está disponible", () => {
  const resolvers: Resolver[] = [
    { id: "local-llm", name: "Apple", role: "llm", local: true, enabled: true },
    { id: "guardado", name: "Guardado", role: "llm", local: false, enabled: true },
    { id: "explicito", name: "Explícito", role: "llm", local: false, enabled: true },
  ];
  assert.equal(manualSummaryResolver(resolvers, "explicito")?.id, "explicito");
  assert.equal(manualSummaryResolver(resolvers, "guardado")?.id, "guardado");
});

test("un LLM guardado inexistente o apagado usa el local de Swift", () => {
  const resolvers: Resolver[] = [
    { id: "local-llm", name: "Apple", role: "llm", local: true, enabled: true },
    { id: "apagado", name: "Apagado", role: "llm", local: false, enabled: false },
    { id: "local-stt", name: "Whisper", role: "stt", local: true, enabled: true },
  ];
  assert.equal(manualSummaryResolver(resolvers, "borrado")?.id, "local-llm");
  assert.equal(manualSummaryResolver(resolvers, "apagado")?.id, "local-llm");
  assert.equal(manualSummaryResolver(resolvers)?.id, "local-llm");
  assert.equal(manualSummaryResolver(resolvers.filter((resolver) => resolver.id !== "local-llm")), undefined);
});
