import { recordTitle, type KnowledgeCollection, type KnowledgeField, type OntologyDefinition } from "../knowledge/model";

export type FilterOperator = "eq" | "ne" | "contains" | "startsWith" | "gt" | "gte" | "lt" | "lte" | "empty" | "notEmpty";
export type FilterCondition = { ontologyId: string; table: string; field: string; operator: FilterOperator; value?: unknown };
export type LibraryFilter = { kind: "visual"; match: "all" | "any"; conditions: FilterCondition[] } | { kind: "surrealql"; ontologyId: string; sql: string };
export type SavedLibraryFilter = { id: string; name: string; filter: LibraryFilter };
export type SaveLibraryFilter = Omit<SavedLibraryFilter, "id"> & { id?: string };
export type RecordTarget = { ontologyId?: string; table: string; value: "id" | "reference" };
export type FieldChoice = KnowledgeField & { recordTarget?: RecordTarget };

export function filterFields(collection: KnowledgeCollection, ontologyId: string): FieldChoice[] {
  const fields: FieldChoice[] = [
    { key: "id", label: "Identidad", type: "text", recordTarget: { table: collection.table, value: "id" } },
    ...collection.fields.filter((field) => field.key !== "id").map((field) => {
      if (field.type === "reference" && field.reference) return { ...field, recordTarget: { ontologyId: field.reference.ontologyId, table: field.reference.table, value: "reference" as const } };
      if (ontologyId === "escriba" && collection.table === "recording" && field.key === "currentVersion") return { ...field, recordTarget: { ontologyId: "escriba", table: "version", value: "id" as const } };
      return field;
    }),
  ];
  if (collection.relation) {
    if (!fields.some((field) => field.key === "in")) fields.push({ key: "in", label: `Origen (${collection.relation.from})`, type: "text", recordTarget: { table: collection.relation.from, value: "id" } });
    if (!fields.some((field) => field.key === "out")) fields.push({ key: "out", label: `Destino (${collection.relation.to})`, type: "text", recordTarget: { table: collection.relation.to, value: "id" } });
  }
  return fields;
}

export function filterOperators(field: FieldChoice): { value: FilterOperator; label: string }[] {
  const choices: { value: FilterOperator; label: string }[] = [
    { value: "eq", label: "es" }, { value: "ne", label: "no es" },
  ];
  if (!field.recordTarget && field.type === "text") choices.push({ value: "contains", label: "contiene" }, { value: "startsWith", label: "empieza por" });
  if (!field.recordTarget && field.type === "json") choices.push({ value: "contains", label: "contiene" });
  if (!field.recordTarget && (field.type === "number" || field.type === "date")) choices.push(
    { value: "gt", label: "mayor que" }, { value: "gte", label: "mayor o igual" },
    { value: "lt", label: "menor que" }, { value: "lte", label: "menor o igual" },
  );
  choices.push({ value: "empty", label: "está vacío" }, { value: "notEmpty", label: "no está vacío" });
  return choices;
}

export function conditionText(field: FieldChoice | undefined, value: unknown): string {
  if (field?.type === "json" && !field.recordTarget) return JSON.stringify(value) ?? "";
  return value == null ? "" : typeof value === "string" ? value : JSON.stringify(value);
}

export function conditionValue(field: FieldChoice, operator: FilterOperator, raw: string): unknown {
  if (operator === "empty" || operator === "notEmpty") return undefined;
  if (field.type === "boolean" && !field.recordTarget) return raw === "true";
  const text = raw.trim();
  if (!text) throw new Error(`Introduce un valor para «${field.label}».`);
  if (field.recordTarget?.value === "id") return text;
  if (field.recordTarget?.value === "reference") {
    try { return JSON.parse(text); } catch { throw new Error(`Selecciona un registro para «${field.label}».`); }
  }
  if (field.type === "number") {
    const value = Number(text.replace(",", "."));
    if (!Number.isFinite(value)) throw new Error(`«${field.label}» debe ser un número.`);
    return value;
  }
  if (field.type === "date") {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(text) || Number.isNaN(Date.parse(`${text}T00:00:00.000Z`))) throw new Error(`«${field.label}» debe ser una fecha.`);
    return text;
  }
  if (field.type === "reference") {
    try { return JSON.parse(text); } catch { throw new Error(`Selecciona un registro para «${field.label}».`); }
  }
  if (field.type === "json") {
    try { return JSON.parse(text); } catch { if (operator === "contains") return text; throw new Error(`«${field.label}» debe contener JSON válido.`); }
  }
  return text;
}

export function defaultCondition(ontologies: OntologyDefinition[]): FilterCondition | null {
  const ontology = ontologies.find((item) => item.collections.length);
  const collection = ontology?.collections[0];
  if (!ontology || !collection) return null;
  const field = collection.fields.find((item) => item.key === collection.titleField) ?? collection.fields.find((item) => item.key === "name") ?? collection.fields[0] ?? filterFields(collection, ontology.id)[0];
  return { ontologyId: ontology.id, table: collection.table, field: field.key, operator: "eq", value: field.type === "boolean" ? true : "" };
}

export async function filterRecordLabel(
  ontology: OntologyDefinition,
  collection: KnowledgeCollection,
  values: Record<string, unknown>,
  loadEndpoint: (recordId: string) => Promise<Record<string, unknown>>,
): Promise<string> {
  if (!collection.relation || (typeof values[collection.titleField] === "string" && String(values[collection.titleField]).trim())) return recordTitle(collection, values);
  const endpoints = [collection.relation.from, collection.relation.to] as const;
  const ids = [values.in, values.out];
  if (ids.some((id) => typeof id !== "string" || !id)) throw new Error("La relación no contiene extremos válidos.");
  const labels = await Promise.all(endpoints.map(async (table, index) => {
    const target = ontology.collections.find((candidate) => candidate.table === table);
    if (!target) throw new Error(`La colección «${table}» no está disponible.`);
    const detail = await loadEndpoint(ids[index] as string);
    return recordTitle(target, detail);
  }));
  return recordTitle(collection, { ...values, in: labels[0], out: labels[1] });
}
