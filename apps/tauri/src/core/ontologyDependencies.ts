import { z } from "zod";
import type { Recipe } from "../types";

const dependency = z.object({
  id: z.string().trim().min(1).max(200),
  minVersion: z.number().int().min(1).max(0xffffffff),
  maxVersion: z.number().int().min(1).max(0xffffffff),
}).strict().refine((value) => value.maxVersion >= value.minVersion, "Intervalo de versiones inválido");

export type OntologyDependency = z.infer<typeof dependency>;
const escribaDependency: OntologyDependency = { id: "escriba", minVersion: 1, maxVersion: 1 };

export function ontologyDependencies(value: unknown): OntologyDependency[] {
  const parsed = z.array(dependency).max(64).parse(value ?? []);
  if (new Set(parsed.map((item) => item.id)).size !== parsed.length)
    throw Error("La receta declara una ontología repetida");
  return parsed;
}

export function ontologyRequirement(recipe: Recipe, recipes: Recipe[], id: string): OntologyDependency {
  const source = recipe.kind === "form" && recipe.base
    ? recipes.find((candidate) => candidate.id === recipe.base || candidate.name === recipe.base)
    : recipe;
  const requirement = ontologyDependencies(source?.ontologies).find((item) => item.id === id);
  if (!requirement && id === "escriba") return escribaDependency;
  if (!requirement) throw Error(`La receta no declara la ontología «${id}»`);
  return requirement;
}
