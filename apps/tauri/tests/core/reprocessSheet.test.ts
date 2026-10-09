import { describe, expect, test } from "vitest";
import { reprocessChoice, reprocessDraft, reprocessTransition } from "../../src/core/reprocessSheet";
import { recipeFormLoad } from "../../src/core/recipeForm";

const form = recipeFormLoad({
  type: "object",
  properties: { resumir: { type: "boolean", default: true } },
});

describe("parámetros de una sola ejecución al reprocesar", () => {
  test("abre con la receta por defecto y reinicia el borrador al elegir otra", () => {
    const initial = reprocessDraft("default");
    const loaded = reprocessTransition(initial, { type: "loaded", recipeId: "default", load: form, saved: { resumir: false } });
    expect(loaded.values).toEqual({ resumir: false });
    const selected = reprocessTransition(loaded, { type: "select", recipeId: "other" });
    expect(selected).toEqual({ recipeId: "other", load: null, values: {} });
    expect(reprocessTransition(selected, { type: "loaded", recipeId: "default", load: form, saved: { resumir: false } })).toEqual(selected);
  });

  test("edita solo el borrador y entrega overrides explícitos para esta ejecución", () => {
    const initial = reprocessTransition(reprocessDraft("default"), { type: "loaded", recipeId: "default", load: form, saved: { resumir: false } });
    expect(reprocessChoice(initial)).toEqual({ recipeId: "default", values: { resumir: false } });
    const edited = reprocessTransition(initial, { type: "change", values: { resumir: true } });
    expect(reprocessChoice(edited)).toEqual({ recipeId: "default", values: {} });
    expect(initial.values).toEqual({ resumir: false });
  });

  test("sin formulario o con un formulario ilegible usa los valores guardados", () => {
    const noForm = recipeFormLoad(null);
    expect(noForm).toEqual({ kind: "noForm" });
    const problem = recipeFormLoad({ type: "object", properties: { dato: { type: "null" } } });
    expect(problem.kind).toBe("problem");
    for (const load of [noForm, problem]) {
      const draft = reprocessTransition(reprocessDraft("code"), { type: "loaded", recipeId: "code", load, saved: { resumir: false } });
      expect(reprocessChoice(draft)).toEqual({ recipeId: "code" });
    }
  });
});
