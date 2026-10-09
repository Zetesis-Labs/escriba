import { expect, test } from "vitest";
import { recipeWithValues } from "../../src/core/recipeValues";
import type { Recipe } from "../../src/types";

test.each(["form", "code"] as const)("los parámetros puntuales sustituyen los guardados de una receta %s", (kind) => {
  const recipe: Recipe = { id: "reparto", name: "Reparto", kind, values: { idioma: "en", resumir: true } };
  expect(recipeWithValues(recipe, { idioma: "es" }).values).toEqual({ idioma: "es" });
  expect(recipe.values).toEqual({ idioma: "en", resumir: true });
});

test("omitir los parámetros conserva los guardados y un objeto vacío los restablece solo esta vez", () => {
  const recipe: Recipe = { id: "default", name: "Por defecto", kind: "form", values: { resumir: false } };
  expect(recipeWithValues(recipe).values).toEqual({ resumir: false });
  expect(recipeWithValues(recipe, {}).values).toEqual({});
  expect(recipe.values).toEqual({ resumir: false });
});
