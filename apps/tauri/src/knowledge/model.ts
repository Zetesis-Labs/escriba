import type { Collection } from "../generated/Collection";
import type { Field } from "../generated/Field";
import type { GraphRecord } from "../generated/GraphRecord";
import type { ListedOntology } from "../generated/ListedOntology";
import type { Ontology } from "../generated/Ontology";

export type KnowledgeReference = { ontologyId: "escriba"; table: string; id: string };
export type KnowledgeField = Field;
export type KnowledgeCollection = Collection;
export type OntologyDefinition = Ontology;
export type InstalledOntology = ListedOntology;
export type KnowledgeRecord = GraphRecord;

export function extensionOntologies<T extends OntologyDefinition & { builtIn?: boolean }>(ontologies: T[]): T[] {
  return ontologies.filter((ontology) => !ontology.builtIn && ontology.id !== "escriba");
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).filter(([, entry]) => entry !== undefined).sort(([left], [right]) => left.localeCompare(right)).map(([key, entry]) => `${JSON.stringify(key)}:${canonical(entry)}`).join(",")}}`;
  return JSON.stringify(value) ?? "null";
}

export function candidateStatus(candidate: OntologyDefinition, installed: InstalledOntology[]): "install" | "update" | "current" | "older" | "conflict" {
  const current = installed.find((item) => item.id === candidate.id);
  if (!current) return "install";
  if (candidate.version > current.version) return "update";
  if (candidate.version < current.version) return "older";
  const normalized = (ontology: OntologyDefinition) => ({ ...ontology, collections: ontology.collections.map((collection) => ({ ...collection, fields: collection.fields.map((field) => ({ ...field, required: field.required ?? false })) })) });
  return canonical(normalized(candidate)) === canonical(normalized(current)) ? "current" : "conflict";
}

export function parseField(field: KnowledgeField, raw: string | boolean): unknown {
  if (field.type === "boolean") return raw === true;
  const text = String(raw).trim();
  if (!text) {
    if (field.required) throw new Error(`«${field.label}» es obligatorio.`);
    return undefined;
  }
  if (field.type === "number") {
    const value = Number(text.replace(",", "."));
    if (!Number.isFinite(value)) throw new Error(`«${field.label}» debe ser un número.`);
    return value;
  }
  if (field.type === "reference") {
    try {
      const value: unknown = JSON.parse(text);
      if (isKnowledgeReference(value) && field.reference && value.ontologyId === field.reference.ontologyId && value.table === field.reference.table) return value;
    } catch {}
    throw new Error(`«${field.label}» debe referirse a un registro válido de ${field.reference?.table ?? "la base"}.`);
  }
  if (field.type === "json") {
    try { return JSON.parse(text); } catch { throw new Error(`«${field.label}» debe contener JSON válido.`); }
  }
  if (field.type === "date") {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(text) || Number.isNaN(Date.parse(`${text}T00:00:00.000Z`)) || new Date(`${text}T00:00:00.000Z`).toISOString().slice(0, 10) !== text) throw new Error(`«${field.label}» debe ser una fecha válida.`);
    return `${text}T00:00:00.000Z`;
  }
  return text;
}

export function fieldInputText(field: KnowledgeField, value: unknown): string {
  if (field.type === "json") return value === undefined ? "" : JSON.stringify(value);
  const text = fieldText(value);
  return field.type === "date" && /^\d{4}-\d{2}-\d{2}T/.test(text) ? text.slice(0, 10) : text;
}

export function editedFields(collection: KnowledgeCollection, raw: Record<string, string | boolean>, original?: Record<string, unknown>): Record<string, unknown> {
  const values: Record<string, unknown> = {};
  for (const field of collection.fields) {
    const input = raw[field.key] ?? "";
    const initial = field.type === "boolean" ? original?.[field.key] === true : fieldInputText(field, original?.[field.key]);
    const value = original && input === initial ? original[field.key] : parseField(field, input);
    if (value !== undefined) values[field.key] = value;
  }
  return values;
}

export function recordTitle(collection: KnowledgeCollection, values: Record<string, unknown>): string {
  const title = values[collection.titleField];
  if (typeof title === "string" && title.trim()) return title;
  if (collection.relation && typeof values.in === "string" && typeof values.out === "string") return `${values.in} → ${values.out}`;
  return "Registro";
}

export function fieldText(value: unknown): string {
  if (value == null) return "";
  return typeof value === "string" ? value : JSON.stringify(value);
}

export function isKnowledgeReference(value: unknown): value is KnowledgeReference {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Record<string, unknown>;
  return item.ontologyId === "escriba" && typeof item.table === "string" && item.table.length > 0 && typeof item.id === "string" && item.id.startsWith(`${item.table}:`) && item.id.length > item.table.length + 1;
}
