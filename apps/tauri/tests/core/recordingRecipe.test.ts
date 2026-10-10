import { test } from "vitest";
import assert from "node:assert/strict";
import { processingRecipeId } from "../../src/core/recordingRecipe";

test("la receta de una ejecución prevalece sobre la elegida al incorporar y la actual por defecto", () => {
  assert.equal(processingRecipeId({ recipeId: "manual" }, { recipeId: "incorporada" }, { defaultRecipeId: "actual" }), "manual");
});

test("la receta elegida al incorporar prevalece sobre la actual por defecto", () => {
  assert.equal(processingRecipeId({}, { recipeId: "incorporada" }, { defaultRecipeId: "actual" }), "incorporada");
});

test("sin elección propia se consulta la receta actual por defecto", () => {
  assert.equal(processingRecipeId({}, {}, { defaultRecipeId: "anterior" }), "anterior");
  assert.equal(processingRecipeId({}, {}, { defaultRecipeId: "actual" }), "actual");
});
