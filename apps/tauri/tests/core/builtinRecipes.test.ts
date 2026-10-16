import { test } from "vitest";
import assert from "node:assert/strict";
import { builtinProgram, builtinRecipeProblem, BUILTIN_PROGRAMS, BUILTIN_RECIPES, startsFrom, withBuiltinRecipes } from "../../src/core/builtinRecipes";
import { builtinRecipeSources } from "../../runtime-host/defaultRecipe.mjs";

test("cada programa de serie se compila desde su receta", () => {
  assert.deepEqual(Object.keys(builtinRecipeSources), [...BUILTIN_PROGRAMS]);
});

test("una biblioteca con solo «Por defecto» recibe las piezas detrás de ella sin tocar lo suyo", () => {
  const propia = { id: "propia", name: "Mía", kind: "form", values: { llm: "x" } };
  const anterior = [{ id: "default", name: "Renombrada", kind: "form", values: { resumir: false } }, propia];
  const recetas = withBuiltinRecipes(anterior);
  assert.deepEqual(recetas.map((recipe) => recipe.id), ["default", "serie:transcribir", "serie:resumir", "serie:publicar", "propia"]);
  assert.equal(recetas[0], anterior[0]);
  assert.deepEqual(withBuiltinRecipes(recetas).map((recipe) => recipe.id), recetas.map((recipe) => recipe.id));
});

test("una biblioteca nueva tiene las cuatro recetas de serie", () => {
  assert.deepEqual(withBuiltinRecipes([]).map((recipe) => recipe.name), ["Por defecto", "Transcribir", "Resumir", "Publicar"]);
});

test("el programa de serie sale de la receta de formulario, y sin pieza es «Por defecto»", () => {
  assert.equal(builtinProgram({ kind: "form" }), "por-defecto");
  assert.equal(builtinProgram({ kind: "form", builtin: "resumir" }), "resumir");
  assert.equal(builtinProgram({ kind: "form", base: "ejemplo" }), undefined);
  assert.equal(builtinProgram({ kind: "code" }), undefined);
});

test("las recetas de serie conservan su código y una variante solo puede apuntar a una pieza conocida", () => {
  for (const recipe of BUILTIN_RECIPES) assert.equal(builtinRecipeProblem(recipe), undefined);
  assert.match(String(builtinRecipeProblem({ id: "serie:resumir", kind: "form", builtin: "publicar" })), /viene de serie/);
  assert.match(String(builtinRecipeProblem({ id: "default", kind: "form", builtin: "resumir" })), /viene de serie/);
  assert.match(String(builtinRecipeProblem({ id: "serie:resumir", kind: "form", base: "x", builtin: "resumir" })), /otra receta de base/);
  assert.equal(builtinRecipeProblem({ id: "variante", kind: "form", builtin: "resumir" }), undefined);
  assert.match(String(builtinRecipeProblem({ id: "variante", kind: "form", builtin: "traducir" })), /desconocida: traducir/);
  assert.match(String(builtinRecipeProblem({ id: "variante", kind: "form", base: "ejemplo", builtin: "resumir" })), /otra receta de base/);
});

test("una receta parte de un audio salvo Resumir, Publicar y las que declaran partir de una nota, y las de formulario heredan de su base", () => {
  const code = { id: "solo-notas", name: "Solo notas", kind: "code" as const, values: {}, startsFrom: "note" as const };
  const recipes = [...BUILTIN_RECIPES, code, { id: "ejemplo", name: "Ejemplo", kind: "code" as const, values: {} }];
  assert.deepEqual(BUILTIN_RECIPES.map((recipe) => [recipe.id, startsFrom(recipe, recipes)]), [
    ["default", "audio"],
    ["serie:transcribir", "audio"],
    ["serie:resumir", "note"],
    ["serie:publicar", "note"],
  ]);
  assert.equal(startsFrom({ kind: "form", builtin: "resumir" }, recipes), "note");
  assert.equal(startsFrom({ kind: "form", base: "solo-notas" }, recipes), "note");
  assert.equal(startsFrom({ kind: "form", base: "ejemplo" }, recipes), "audio");
  assert.equal(startsFrom(recipes[5], recipes), "audio");
});
