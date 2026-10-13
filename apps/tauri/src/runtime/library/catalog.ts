import { validateAccess } from "../http";
import { ontologyDependencies } from "../../core/ontologyDependencies";
import { isObject, safeId, text, type Json } from "./json";
import { readOntologies, type Ontology } from "./model";
import type { Store } from "./store";

export type SqlValidator = (ontologies: Ontology[]) => Promise<void>;

export function validateCatalog(ontologies: Ontology[]) {
  if (ontologies.length > 64) throw Error("El proyecto declara más de 64 ontologías");
  const ids = new Set<string>();
  let size = 0;
  for (const ontology of ontologies) {
    size += JSON.stringify(ontology).length;
    if (size > 1_048_576) throw Error("Las definiciones de ontología superan 1 MiB");
    if (ontology.id === "escriba") throw Error("La ontología base de Escriba la mantiene la aplicación");
    if (!ontology.id || ontology.id.length > 200 || !ontology.name.trim() || ontology.version === 0)
      throw Error("Ontología sin identidad, nombre o versión válida");
    if (ontology.migrations.length !== ontology.version || ontology.migrations.some((migration, index) => migration.version !== index + 1 || !migration.sql.trim()))
      throw Error("Las migraciones deben ser acumulativas y consecutivas desde 1");
    if (ids.has(ontology.id)) throw Error("Identificador de ontología duplicado");
    ids.add(ontology.id);
  }
}
function dependencies(value: unknown) {
  try {
    ontologyDependencies(value ?? []);
  } catch {
    throw Error("Dependencias de ontología inválidas o repetidas");
  }
}
export async function install(store: Store, pkg: Json, validateSql?: SqlValidator) {
  if (!isObject(pkg)) throw Error("Paquete inválido");
  const ontologies = readOntologies(pkg.ontologies ?? []);
  validateCatalog(ontologies);
  if (validateSql) await validateSql(ontologies);
  const compiled = pkg.recipes;
  if (!Array.isArray(compiled)) throw Error("Recetas compiladas inválidas");
  const destinations = pkg.destinations;
  if (!Array.isArray(destinations)) throw Error("Destinos compilados inválidos");
  let providers: Json[] = [];
  if (pkg.providers !== undefined) {
    if (!Array.isArray(pkg.providers)) throw Error("Proveedores compilados inválidos");
    providers = pkg.providers;
  }
  const next = store.indexJson() as Record<string, Json>;
  (next.settings as Record<string, Json>).projectOntologies = ontologies as unknown as Json;
  const previous = next.recipes;
  if (!Array.isArray(previous)) throw Error("Recetas inválidas");
  const recipes: Record<string, Json>[] = previous.filter((recipe): recipe is Record<string, Json> => isObject(recipe) && recipe.kind !== "code").map((recipe) => ({ ...recipe }));
  const aliases = new Map<string, string>();
  const installed = new Set<string>();
  for (const built of compiled) {
    if (!isObject(built)) throw Error("Paquete de receta inválido");
    dependencies(built.ontologies);
    const id = text(built, "id");
    if (built.kind !== "code" || typeof built.bundle !== "string") throw Error("Paquete de receta inválido");
    const old = previous.find((recipe) => isObject(recipe) && recipe.kind === "code" && (recipe.id === id || (typeof built.entry === "string" && recipe.entry === built.entry))) as Record<string, Json> | undefined;
    const recipe: Record<string, Json> = { ...built };
    if (old) {
      aliases.set(text(old, "id"), id);
      recipe.values = old.values as Json;
      installed.add(text(old, "id"));
    }
    installed.add(id);
    recipes.push(recipe);
  }
  for (const old of previous) {
    if (!isObject(old) || old.kind !== "code") continue;
    if (!installed.has(text(old, "id"))) {
      const { bundle: _bundle, ...missing } = old;
      recipes.push({ ...missing, error: "No se encontró la fuente al compilar el proyecto" });
    }
  }
  const remap = (holder: Record<string, Json>, key: string) => {
    const value = holder[key];
    if (typeof value === "string" && aliases.has(value)) holder[key] = aliases.get(value)!;
  };
  for (const recipe of recipes) if (recipe.kind === "form") remap(recipe, "base");
  remap(next.settings as Record<string, Json>, "defaultRecipeId");
  for (const record of next.recordings as Record<string, Json>[]) {
    if (record.status === "discarded") continue;
    remap(record, "recipeId");
    const versions = record.versions;
    if (!Array.isArray(versions)) throw Error("Versiones inválidas");
    for (const version of versions) if (isObject(version)) remap(version, "recipeId");
  }
  next.recipes = recipes;
  const previousDestinations = store.data.destinations;
  if (!Array.isArray(previousDestinations)) throw Error("Destinos inválidos");
  const nextDestinations: Record<string, Json>[] = [
    ...previousDestinations.filter((destination): destination is Record<string, Json> => isObject(destination) && (destination.managed === true || destination.program === null || destination.program === undefined)).map((destination) => ({ ...destination })),
    ...destinations.map((destination) => {
      if (!isObject(destination)) return destination as unknown as Record<string, Json>;
      const { managed: _managed, ...rest } = destination;
      return rest;
    }),
  ];
  for (const destination of nextDestinations) {
    if (destination.managed === true) {
      const provider = providers.find((provider) => isObject(provider) && provider.id === destination.provider) as Record<string, Json> | undefined;
      if (provider) {
        destination.program = provider.program ?? null;
        destination.programFingerprint = provider.programFingerprint ?? null;
      }
    }
    const old = previousDestinations.find((item) => isObject(item) && item.id === destination.id) as Record<string, Json> | undefined;
    if (old) destination.enabled = old.enabled ?? null;
  }
  next.destinations = nextDestinations;
  const previousProviders = store.data.providers;
  if (!Array.isArray(previousProviders)) throw Error("Proveedores inválidos");
  const installedProviders = new Set<string>();
  const nextProviders: Record<string, Json>[] = [];
  for (const provider of providers) {
    if (!isObject(provider)) throw Error("Proveedor compilado inválido");
    const id = text(provider, "id");
    safeId(id);
    if (["notion", "okf"].includes(id) || typeof provider.name !== "string" || !provider.name.trim() || !isObject(provider.defaultConfiguration) || typeof provider.program !== "string" || !provider.program)
      throw Error("Proveedor compilado inválido");
    validateAccess(provider);
    installedProviders.add(id);
    nextProviders.push({ ...provider, unavailable: false });
  }
  for (const old of previousProviders) {
    if (!isObject(old)) continue;
    if (!installedProviders.has(text(old, "id"))) nextProviders.push({ ...old, unavailable: true });
  }
  next.providers = nextProviders;
  for (const collection of ["recipes", "destinations", "providers"]) {
    const keys = new Set<string>();
    for (const item of next[collection] as Json[]) {
      const key = text(item, "id");
      if (keys.has(key)) throw Error(`Identificador duplicado en ${collection}: ${key}`);
      keys.add(key);
    }
  }
  await store.replaceCatalog(next, aliases);
}
