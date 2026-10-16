import { build } from "esbuild";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const recipes = resolve(app, "../../recetas");
export const builtinRecipeSources = Object.fromEntries(
  ["por-defecto", "transcribir", "resumir", "publicar"].map((program) => [program, resolve(recipes, program, "receta.ts")]),
);
export const defaultRecipeSource = builtinRecipeSources["por-defecto"];
export const piecesSource = resolve(recipes, "piezas.ts");

async function buildRecipe(source) {
  const built = await build({
    entryPoints: [source],
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    globalName: "__recipe",
    target: "es2022",
    external: ["zod"],
    logLevel: "warning",
  });
  return built.outputFiles[0].text;
}

export async function buildBuiltinRecipes() {
  const entries = await Promise.all(
    Object.entries(builtinRecipeSources).map(async ([program, source]) => [program, await buildRecipe(source)]),
  );
  return Object.fromEntries(entries);
}
