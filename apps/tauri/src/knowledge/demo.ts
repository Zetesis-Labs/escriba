import type { KnowledgeRecord, OntologyDefinition, RuntimeHost } from "./model";

export const demoOntology: OntologyDefinition = {
  id: "demo.reuniones", name: "Reuniones", version: 1, migrations: [{ version: 1, sql: "-- Ejemplo visual; no se instala en una biblioteca real" }],
  collections: [
    { table: "acuerdos", label: "Acuerdos", titleField: "titulo", fields: [
      { key: "titulo", label: "Título", type: "text", required: true },
      { key: "responsable", label: "Responsable", type: "reference", reference: { ontologyId: "escriba", table: "person" } },
      { key: "fecha", label: "Fecha", type: "date" },
      { key: "hecho", label: "Completado", type: "boolean" },
    ] },
  ],
};

const demoBase: OntologyDefinition = {
  id: "escriba", name: "Escriba", version: 1, builtIn: true, migrations: [],
  collections: [
    ...([ ["person", "Personas", "name"], ["recording", "Grabaciones", "title"], ["version", "Versiones", "title"], ["transcript", "Transcripciones", "text"], ["speaker", "Hablantes", "name"], ["segment", "Segmentos", "text"], ["word", "Palabras", "text"] ] as const).map(([table, label, titleField]) => ({ table, label, titleField, fields: [{ key: titleField, label: titleField, type: "text" as const }] })),
    ...([ ["has_version", "recording", "version"], ["has_transcript", "version", "transcript"], ["has_segment", "transcript", "segment"], ["has_word", "segment", "word"], ["spoken_by", "segment", "speaker"], ["identified_as", "speaker", "person"], ["derived_from", "version", "version"] ] as const).map(([table, from, to]) => ({ table, label: table, titleField: "id", fields: [], relation: { from, to } })),
  ],
};

export function demoKnowledgeHost(recordingId: string): RuntimeHost {
  let installed: OntologyDefinition[] = [demoBase, demoOntology];
  let records: KnowledgeRecord[] = [
    { id: "person:ana", ontologyId: "escriba", table: "person", values: { name: "Ana" }, rev: "1" },
    { id: "acuerdos:ejemplo", ontologyId: demoOntology.id, table: "acuerdos", values: { titulo: "Enviar el borrador", responsable: { ontologyId: "escriba", table: "person", id: "person:ana" }, fecha: "2026-10-14T00:00:00.000Z", hecho: false }, recordingId, rev: "1" },
  ];
  const links = new Map<string, Set<string>>([["acuerdos:ejemplo", new Set([recordingId])]]);
  return async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
    if (method === "knowledge_list") return installed as T;
    if (method === "knowledge_candidates") return [demoOntology] as T;
    if (method === "knowledge_install") { const definition = params.definition as OntologyDefinition; installed = [demoBase, ...installed.filter((item) => item.id !== "escriba" && item.id !== definition.id), definition]; return definition as T; }
    if (method === "knowledge_records") {
      const page = Number(params.page ?? 0);
      return { records: page ? [] : records.filter((record) => record.ontologyId === params.id && record.table === params.table && (!params.recordingId || links.get(record.id)?.has(String(params.recordingId)))), page, hasMore: false } as T;
    }
    if (method === "knowledge_save") {
      const prior = records.find((record) => record.id === params.recordId);
      if (prior && prior.rev !== params.expectedRev) throw new Error("El registro cambió mientras lo editabas. Copia tus cambios y vuelve a cargarlo.");
      const saved: KnowledgeRecord = { id: prior?.id ?? `acuerdos:${crypto.randomUUID()}`, ontologyId: String(params.id), table: String(params.table), values: params.values as Record<string, unknown>, recordingId, rev: String(Number(prior?.rev ?? 0) + 1) };
      records = prior ? records.map((record) => record.id === prior.id ? saved : record) : [...records, saved];
      links.set(saved.id, new Set([...(links.get(saved.id) ?? []), recordingId]));
      return saved as T;
    }
    if (method === "knowledge_delete") { records = records.filter((record) => record.id !== params.recordId); links.delete(String(params.recordId)); return undefined as T; }
    if (method === "knowledge_attach") { links.set(String(params.recordId), new Set([...(links.get(String(params.recordId)) ?? []), String(params.recordingId)])); return undefined as T; }
    if (method === "knowledge_unlink") { links.get(String(params.recordId))?.delete(String(params.recordingId)); return undefined as T; }
    throw new Error(`Comando de ejemplo desconocido: ${method}`);
  };
}
