export type KnowledgeReference = { ontologyId: "escriba"; table: string; id: string };
export type KnowledgeField = { key: string; label: string; type: "text" | "number" | "boolean" | "date" | "json" | "reference"; required?: boolean; reference?: { ontologyId: "escriba"; table: string } };
export type KnowledgeCollection = { table: string; label: string; titleField: string; fields: KnowledgeField[]; relation?: { from: string; to: string } };
export type OntologyDefinition = { id: string; name: string; version: number; builtIn?: boolean; migrations: { version: number; sql: string }[]; collections: KnowledgeCollection[] };
export type InstalledOntology = OntologyDefinition;
export type KnowledgeRecord = { id: string; ontologyId: string; table: string; values: Record<string, unknown>; rev: string; recordingId?: string | null; versionId?: string | null };
export type RecordPage = { records: KnowledgeRecord[]; page: number; hasMore: boolean };
export type RuntimeHost = <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;

export function extensionOntologies<T extends OntologyDefinition>(ontologies: T[]): T[] {
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

export function isInstalledOntology(value: unknown): value is InstalledOntology {
  if (!value || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return typeof item.id === "string" && typeof item.name === "string" && Number.isInteger(item.version) && (item.builtIn === undefined || typeof item.builtIn === "boolean") && Array.isArray(item.collections) && item.collections.every(isCollection) && Array.isArray(item.migrations) && item.migrations.every((migration) => !!migration && typeof migration === "object" && Number.isInteger((migration as Record<string, unknown>).version) && typeof (migration as Record<string, unknown>).sql === "string");
}

export function isKnowledgeReference(value: unknown): value is KnowledgeReference {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Record<string, unknown>;
  return item.ontologyId === "escriba" && typeof item.table === "string" && item.table.length > 0 && typeof item.id === "string" && item.id.startsWith(`${item.table}:`) && item.id.length > item.table.length + 1;
}

export function isDefinition(value: unknown): value is OntologyDefinition {
  return isInstalledOntology(value);
}

function isCollection(value: unknown): value is KnowledgeCollection {
  if (!value || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  const relation = item.relation;
  const validRelation = relation == null || (typeof relation === "object" && typeof (relation as Record<string, unknown>).from === "string" && typeof (relation as Record<string, unknown>).to === "string");
  return validRelation && typeof item.table === "string" && typeof item.label === "string" && typeof item.titleField === "string" && Array.isArray(item.fields) && item.fields.every((field) => {
    if (!field || typeof field !== "object") return false;
    const candidate = field as Record<string, unknown>;
    const reference = candidate.reference;
    return typeof candidate.key === "string" && typeof candidate.label === "string" && (candidate.required === undefined || typeof candidate.required === "boolean") && ["text", "number", "boolean", "date", "json", "reference"].includes(String(candidate.type)) && (candidate.type === "reference" ? !!reference && typeof reference === "object" && (reference as Record<string, unknown>).ontologyId === "escriba" && typeof (reference as Record<string, unknown>).table === "string" && String((reference as Record<string, unknown>).table).length > 0 : reference === undefined);
  });
}

export function isRecordPage(value: unknown): value is RecordPage {
  if (!value || typeof value !== "object") return false;
  const page = value as Record<string, unknown>;
  return Array.isArray(page.records) && Number.isInteger(page.page) && typeof page.hasMore === "boolean" && page.records.every((record) => {
    if (!record || typeof record !== "object") return false;
    const item = record as Record<string, unknown>;
    return typeof item.id === "string" && typeof item.ontologyId === "string" && typeof item.table === "string" && typeof item.rev === "string" && !!item.values && typeof item.values === "object" && !Array.isArray(item.values);
  });
}
