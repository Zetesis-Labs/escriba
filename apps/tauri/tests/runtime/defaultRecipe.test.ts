import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";
import { defaultRecipeSource, piecesSource } from "../../runtime-host/defaultRecipe.mjs";

test("la receta y las piezas que Rust copia a los proyectos son las que compila el runtime", () => {
  const sources = fileURLToPath(new URL("../../src-tauri/src/", import.meta.url));
  const project = readFileSync(resolve(sources, "project.rs"), "utf8");
  const included = (name: string) => new RegExp(`const ${name}: &str = include_str!\\("([^"]+)"\\);`).exec(project)?.[1];
  expect(resolve(sources, included("EXAMPLE") ?? "")).toBe(defaultRecipeSource);
  expect(resolve(sources, included("PIECES") ?? "")).toBe(piecesSource);
});

test("la interfaz no importa la receta por defecto desde fuera de la app", () => {
  const module = readFileSync(new URL("../../src/runtime/defaultRecipe.ts", import.meta.url), "utf8");
  expect(module).not.toMatch(/from "\.\.\/\.\.\/\.\.\/\.\.\//);
});

const resolutor = (clave: string, local: boolean) => ({ clave, nombre: clave, local, modelo: null, url: null });

test("sin LLMs, como en Linux de serie, la receta por defecto se puede usar y resume sin LLM elegido", async () => {
  const { buildRecipeForm } = await import("../../../../recetas/por-defecto/receta");
  const parametros = buildRecipeForm({ stts: [resolutor("local-stt", true)], llms: [], conectores: [], recetas: [] }).parse({});
  expect(parametros.stt).toBe("local-stt");
  expect(parametros.resumir).toBe(true);
  expect(parametros.llm).toBeNull();
});

test("con LLMs la receta por defecto usa el local o, sin él, el primero", async () => {
  const { buildRecipeForm } = await import("../../../../recetas/por-defecto/receta");
  const listas = (llms: ReturnType<typeof resolutor>[]) => ({ stts: [resolutor("local-stt", true)], llms, conectores: [], recetas: [] });
  expect(buildRecipeForm(listas([resolutor("remoto", false), resolutor("local-llm", true)])).parse({}).llm).toBe("local-llm");
  expect(buildRecipeForm(listas([resolutor("remoto", false)])).parse({}).llm).toBe("remoto");
});
