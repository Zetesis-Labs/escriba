import { test } from "vitest";
import assert from "node:assert/strict";
import { ontologyDependencies, ontologyRequirement } from "../../src/core/ontologyDependencies";

test("una receta declara intervalos explícitos de ontología sin identificadores repetidos", () => {
  const dependency = { id: "ejemplo.temas", minVersion: 1, maxVersion: 3 };
  assert.deepEqual(ontologyDependencies([dependency]), [dependency]);
  assert.deepEqual(ontologyDependencies(undefined), []);
  assert.throws(() => ontologyDependencies([{ ...dependency, maxVersion: 0 }]));
  assert.throws(() => ontologyDependencies([dependency, dependency]));
  assert.throws(() => ontologyDependencies([{ ...dependency, minVersion: 1.5 }]));
});

test("el acceso usa las dependencias de la receta de código también desde un formulario", () => {
  const recipes = [
    { id: "codigo", kind: "code" as const, name: "Código", values: {}, ontologies: [{ id: "temas", minVersion: 1, maxVersion: 2 }] },
    { id: "form", kind: "form" as const, name: "Formulario", values: {}, base: "codigo" },
  ];
  assert.equal(ontologyRequirement(recipes[1], recipes, "temas").maxVersion, 2);
  assert.throws(() => ontologyRequirement(recipes[1], recipes, "ajena"), /no declara/);
});
