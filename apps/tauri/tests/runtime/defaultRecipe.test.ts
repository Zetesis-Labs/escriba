import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";
import { defaultRecipeSource } from "../../runtime-host/defaultRecipe.mjs";

test("la receta que Rust copia a los proyectos y la que compila el runtime son el mismo fichero", () => {
  const sources = fileURLToPath(new URL("../../src-tauri/src/", import.meta.url));
  const project = readFileSync(resolve(sources, "project.rs"), "utf8");
  const included = /const EXAMPLE: &str = include_str!\("([^"]+)"\);/.exec(project)?.[1];
  expect(included && resolve(sources, included)).toBe(defaultRecipeSource);
});

test("la interfaz no importa la receta por defecto desde fuera de la app", () => {
  const module = readFileSync(new URL("../../src/runtime/defaultRecipe.ts", import.meta.url), "utf8");
  expect(module).not.toMatch(/from "\.\.\/\.\.\/\.\.\/\.\.\//);
});
