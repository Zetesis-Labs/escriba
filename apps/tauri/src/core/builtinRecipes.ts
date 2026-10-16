import type { Recipe } from "../types";

export const BUILTIN_PROGRAMS = ["por-defecto", "transcribir", "resumir", "publicar"] as const;
export type BuiltinProgram = (typeof BUILTIN_PROGRAMS)[number];

const NAMES: Record<BuiltinProgram, string> = {
  "por-defecto": "Por defecto",
  transcribir: "Transcribir",
  resumir: "Resumir",
  publicar: "Publicar",
};

export function builtinRecipeId(program: BuiltinProgram): string {
  return program === "por-defecto" ? "default" : `serie:${program}`;
}

export const BUILTIN_RECIPES: readonly Recipe[] = [
  { id: builtinRecipeId("por-defecto"), name: NAMES["por-defecto"], kind: "form", values: {} },
  ...(["transcribir", "resumir", "publicar"] as const).map((program): Recipe => ({
    id: builtinRecipeId(program),
    name: NAMES[program],
    kind: "form",
    builtin: program,
    values: {},
  })),
];

export function isBuiltinProgram(value: unknown): value is BuiltinProgram {
  return BUILTIN_PROGRAMS.some((program) => program === value);
}

export function builtinProgram(recipe: Pick<Recipe, "kind" | "base" | "builtin">): BuiltinProgram | undefined {
  if (recipe.kind !== "form" || recipe.base) return undefined;
  return recipe.builtin ?? "por-defecto";
}

const ROLES: Record<BuiltinProgram, readonly ("stt" | "llm")[]> = {
  "por-defecto": ["stt", "llm"],
  transcribir: ["stt"],
  resumir: ["llm"],
  publicar: [],
};

export function builtinRoles(program: BuiltinProgram): readonly ("stt" | "llm")[] {
  return ROLES[program];
}

export function builtinProgramName(program: BuiltinProgram): string {
  return NAMES[program];
}

export function isBuiltinRecipeId(id: string): boolean {
  return BUILTIN_RECIPES.some((recipe) => recipe.id === id);
}

export function builtinRecipeProblem(recipe: { id?: unknown; kind?: unknown; base?: unknown; builtin?: unknown }): string | undefined {
  const seeded = BUILTIN_RECIPES.find((candidate) => candidate.id === recipe.id);
  if (seeded && recipe.kind === "form" && !recipe.base && (recipe.builtin ?? "por-defecto") !== builtinProgram(seeded))
    return `«${seeded.name}» viene de serie y conserva su código`;
  if (recipe.builtin === undefined) return undefined;
  if (!isBuiltinProgram(recipe.builtin)) return `Receta de serie desconocida: ${String(recipe.builtin)}`;
  if (recipe.kind !== "form" || recipe.base) return "Una receta de serie no puede tener otra receta de base";
  return undefined;
}

const idOf = (recipe: unknown) => (typeof recipe === "object" && recipe !== null && "id" in recipe ? recipe.id : undefined);

export function withBuiltinRecipes<T>(recipes: readonly T[]): (T | Recipe)[] {
  const missing = BUILTIN_RECIPES.filter((builtin) => !recipes.some((recipe) => idOf(recipe) === builtin.id)).map((builtin) => structuredClone(builtin));
  if (!missing.length) return [...recipes];
  const at = recipes.findIndex((recipe) => idOf(recipe) === "default") + 1;
  return [...recipes.slice(0, at), ...missing, ...recipes.slice(at)];
}
