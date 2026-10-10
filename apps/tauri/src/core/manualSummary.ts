import type { Recipe, Resolver } from "../types";

export function manualSummaryReading(defaultRecipeId: string, recipes: Recipe[]): {
  llm?: string;
  language: string | null;
  prompt?: string;
} {
  const recipe = recipes.find((candidate) => candidate.id === defaultRecipeId);
  const values = recipe?.kind === "form" && !recipe.base ? recipe.values : {};
  return {
    llm: typeof values.llm === "string" ? values.llm : undefined,
    language: values.idioma === null ? null : typeof values.idioma === "string" ? values.idioma : "es",
    prompt: typeof values.prompt === "string" ? values.prompt : undefined,
  };
}

export function manualSummaryResolver(resolvers: Resolver[], preferred?: string): Resolver | undefined {
  const available = resolvers.filter((resolver) => resolver.role === "llm" && resolver.enabled);
  return available.find((resolver) => resolver.id === preferred) ?? available.find((resolver) => resolver.local);
}
