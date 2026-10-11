import { build } from "esbuild";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const defaultRecipeSource = resolve(app, "../../recetas/por-defecto/receta.ts");

export async function buildDefaultRecipe() {
  const built = await build({
    entryPoints: [defaultRecipeSource],
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
