import type { KnowledgeRecord, OntologyDefinition, RuntimeHost } from "./model";
import type { GraphData, GraphEdge, GraphNode, GraphPage } from "./graphTypes";

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

export const demoClientsOntology: OntologyDefinition = {
  id: "demo.clientes", name: "Clientes", version: 1, migrations: [{ version: 1, sql: "-- Ejemplo visual; no se instala en una biblioteca real" }],
  collections: [
    { table: "cliente", label: "Clientes", titleField: "nombre", fields: [
      { key: "nombre", label: "Nombre", type: "text", required: true },
      { key: "sector", label: "Sector", type: "text" },
      { key: "ciudad", label: "Ciudad", type: "text" },
      { key: "responsable", label: "Responsable", type: "reference", reference: { ontologyId: "escriba", table: "person" } },
    ] },
    { table: "contacto", label: "Contactos", titleField: "nombre", fields: [
      { key: "nombre", label: "Nombre", type: "text", required: true },
      { key: "cargo", label: "Cargo", type: "text" },
      { key: "persona", label: "Persona de la biblioteca", type: "reference", reference: { ontologyId: "escriba", table: "person" } },
    ] },
    { table: "pertenece_a", label: "Trabaja en", titleField: "cargo", relation: { from: "contacto", to: "cliente" }, fields: [{ key: "cargo", label: "Cargo", type: "text" }] },
    { table: "colabora_con", label: "Colabora con", titleField: "proyecto", relation: { from: "cliente", to: "cliente" }, fields: [{ key: "proyecto", label: "Proyecto", type: "text" }] },
    { table: "factura_a", label: "Factura a", titleField: "modalidad", relation: { from: "cliente", to: "cliente" }, fields: [{ key: "modalidad", label: "Modalidad", type: "text" }] },
  ],
};

const demoBase: OntologyDefinition = {
  id: "escriba", name: "Escriba", version: 1, builtIn: true, migrations: [],
  collections: [
    ...([ ["person", "Personas", "name"], ["recording", "Grabaciones", "title"], ["version", "Versiones", "title"], ["transcript", "Transcripciones", "text"], ["speaker", "Hablantes", "name"], ["segment", "Segmentos", "text"], ["word", "Palabras", "text"] ] as const).map(([table, label, titleField]) => ({ table, label, titleField, fields: [{ key: titleField, label: titleField, type: "text" as const }] })),
    ...([ ["has_version", "Tiene versión", "recording", "version"], ["has_transcript", "Tiene transcripción", "version", "transcript"], ["has_segment", "Contiene segmento", "transcript", "segment"], ["has_word", "Contiene palabra", "segment", "word"], ["spoken_by", "Dicho por", "segment", "speaker"], ["identified_as", "Asignado a persona", "speaker", "person"], ["derived_from", "Corregida desde", "version", "version"] ] as const).map(([table, label, from, to]) => ({ table, label, titleField: "title", fields: [], relation: { from, to } })),
  ],
};

const graphKey = (ontologyId: string, recordId: string) => JSON.stringify([ontologyId, recordId]);
const demoReference = (id: string) => ({ ontologyId: "escriba", table: "person", id });
const demoPageSize = 40;

function demoGraph(records: readonly KnowledgeRecord[], definitions: readonly OntologyDefinition[]): GraphData {
  const nodes = new Map<string, GraphNode>();
  const edges: GraphEdge[] = [];
  const byRecord = new Map(records.map((record) => [graphKey(record.ontologyId, record.id), record]));
  const addNode = (ontologyId: string, recordId: string) => {
    const key = graphKey(ontologyId, recordId);
    if (nodes.has(key)) return key;
    const record = byRecord.get(key);
    const collection = definitions.find((item) => item.id === ontologyId)?.collections.find((item) => item.table === (record?.table ?? recordId.split(":")[0]));
    const title = collection?.titleField;
    nodes.set(key, { key, ontologyId, recordId, table: record?.table ?? recordId.split(":")[0] ?? "", label: record ? String(record.values[title ?? ""] ?? recordId) : recordId, missing: !record });
    return key;
  };
  for (const record of records) {
    const collection = definitions.find((item) => item.id === record.ontologyId)?.collections.find((item) => item.table === record.table);
    if (collection?.relation) {
      const from = record.values.in;
      const to = record.values.out;
      if (typeof from === "string" && typeof to === "string") edges.push({ key: graphKey(record.ontologyId, record.id), source: addNode(record.ontologyId, from), target: addNode(record.ontologyId, to), label: collection.label, kind: "relation", ontologyId: record.ontologyId, table: record.table, recordId: record.id });
    } else addNode(record.ontologyId, record.id);
    for (const field of collection?.fields ?? []) {
      if (!field.reference) continue;
      const value = record.values[field.key];
      if (!value || typeof value !== "object" || !("id" in value) || typeof value.id !== "string") continue;
      edges.push({ key: JSON.stringify(["reference", record.ontologyId, record.id, field.key]), source: addNode(record.ontologyId, record.id), target: addNode(field.reference.ontologyId, value.id), label: field.label, kind: "reference", ontologyId: record.ontologyId, table: record.table, recordId: record.id, field: field.key });
    }
    if (record.versionId && record.recordingId) {
      const version = `version:[${JSON.stringify(record.recordingId)},${JSON.stringify(record.versionId)}]`;
      edges.push({ key: JSON.stringify(["provenance", record.ontologyId, record.id, record.recordingId, record.versionId]), source: addNode(record.ontologyId, record.id), target: addNode("escriba", version), label: "Procedencia", kind: "provenance", ontologyId: record.ontologyId, table: record.table, recordId: record.id });
    }
  }
  return { nodes: [...nodes.values()], edges };
}

function graphPage(graph: GraphData, edgeSubset: GraphEdge[], page: number, root?: string): GraphPage {
  const start = page * demoPageSize;
  const chosen = edgeSubset.slice(start, start + demoPageSize);
  const keys = new Set(chosen.flatMap((edge) => [edge.source, edge.target]));
  if (root) keys.add(root);
  return { nodes: graph.nodes.filter((node) => keys.has(node.key)), edges: chosen, page, hasMore: start + demoPageSize < edgeSubset.length, ...(root ? { root } : {}) };
}

export function demoKnowledgeHost(recordingId: string): RuntimeHost {
  let installed: OntologyDefinition[] = [demoBase, demoClientsOntology, demoOntology];
  let records: KnowledgeRecord[] = [
    { id: "person:ana", ontologyId: "escriba", table: "person", values: { name: "Ana" }, rev: "1" },
    { id: "person:luis", ontologyId: "escriba", table: "person", values: { name: "Luis" }, rev: "1" },
    { id: "person:ines", ontologyId: "escriba", table: "person", values: { name: "Inés" }, rev: "1" },
    { id: "version:[\"demo-rec-aurora\",\"v1\"]", ontologyId: "escriba", table: "version", values: { title: "Reunión de lanzamiento" }, rev: "1" },
    { id: "version:[\"demo-rec-aurora\",\"v2\"]", ontologyId: "escriba", table: "version", values: { title: "Seguimiento de Aurora" }, rev: "1" },
    { id: "cliente:aurora", ontologyId: demoClientsOntology.id, table: "cliente", values: { nombre: "Cliente Aurora", sector: "Diseño y tecnología", ciudad: "Madrid", responsable: demoReference("person:ana") }, recordingId: "demo-rec-aurora", versionId: "v1", rev: "1" },
    { id: "cliente:norte", ontologyId: demoClientsOntology.id, table: "cliente", values: { nombre: "Estudio Norte", sector: "Arquitectura", ciudad: "Bilbao", responsable: demoReference("person:luis") }, rev: "1" },
    { id: "cliente:rio", ontologyId: demoClientsOntology.id, table: "cliente", values: { nombre: "Editorial Río", sector: "Cultura", ciudad: "Barcelona", responsable: demoReference("person:ines") }, rev: "1" },
    { id: "contacto:lucia", ontologyId: demoClientsOntology.id, table: "contacto", values: { nombre: "Lucía Martín", cargo: "Dirección de producto", persona: demoReference("person:ana") }, recordingId: "demo-rec-aurora", versionId: "v2", rev: "1" },
    { id: "contacto:marcos", ontologyId: demoClientsOntology.id, table: "contacto", values: { nombre: "Marcos Vega", cargo: "Diseño", persona: demoReference("person:luis") }, rev: "1" },
    { id: "contacto:ines", ontologyId: demoClientsOntology.id, table: "contacto", values: { nombre: "Inés Soler", cargo: "Operaciones", persona: demoReference("person:ines") }, rev: "1" },
    { id: "pertenece_a:lucia_aurora", ontologyId: demoClientsOntology.id, table: "pertenece_a", values: { in: "contacto:lucia", out: "cliente:aurora", cargo: "Dirección de producto" }, rev: "1" },
    { id: "pertenece_a:marcos_aurora", ontologyId: demoClientsOntology.id, table: "pertenece_a", values: { in: "contacto:marcos", out: "cliente:aurora", cargo: "Diseño" }, rev: "1" },
    { id: "pertenece_a:ines_aurora", ontologyId: demoClientsOntology.id, table: "pertenece_a", values: { in: "contacto:ines", out: "cliente:aurora", cargo: "Operaciones" }, rev: "1" },
    { id: "colabora_con:aurora_norte", ontologyId: demoClientsOntology.id, table: "colabora_con", values: { in: "cliente:aurora", out: "cliente:norte", proyecto: "Archivo común" }, rev: "1" },
    { id: "colabora_con:aurora_rio", ontologyId: demoClientsOntology.id, table: "colabora_con", values: { in: "cliente:aurora", out: "cliente:rio", proyecto: "Colección de entrevistas" }, rev: "1" },
    { id: "factura_a:aurora_norte", ontologyId: demoClientsOntology.id, table: "factura_a", values: { in: "cliente:aurora", out: "cliente:norte", modalidad: "Servicios compartidos" }, rev: "1" },
    { id: "factura_a:aurora_central", ontologyId: demoClientsOntology.id, table: "factura_a", values: { in: "cliente:aurora", out: "cliente:aurora", modalidad: "Facturación directa de la entidad central" }, rev: "1" },
    { id: "acuerdos:ejemplo", ontologyId: demoOntology.id, table: "acuerdos", values: { titulo: "Enviar el borrador", responsable: { ontologyId: "escriba", table: "person", id: "person:ana" }, fecha: "2026-10-14T00:00:00.000Z", hecho: false }, recordingId, rev: "1" },
  ];
  const links = new Map<string, Set<string>>([["acuerdos:ejemplo", new Set([recordingId])]]);
  return async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
    if (method === "knowledge_list") return installed as T;
    if (method === "knowledge_candidates") return [demoClientsOntology, demoOntology] as T;
    if (method === "knowledge_install") { const definition = params.definition as OntologyDefinition; installed = [demoBase, ...installed.filter((item) => item.id !== "escriba" && item.id !== definition.id), definition]; return definition as T; }
    if (method === "knowledge_records") {
      const page = Number(params.page ?? 0);
      return { records: page ? [] : records.filter((record) => record.ontologyId === params.id && record.table === params.table && (!params.recordingId || links.get(record.id)?.has(String(params.recordingId)))), page, hasMore: false } as T;
    }
    if (method === "knowledge_graph_roots") {
      const ontologyId = String(params.ontologyId);
      const table = String(params.table);
      const page = Number(params.page ?? 0);
      const collection = installed.find((item) => item.id === ontologyId)?.collections.find((item) => item.table === table);
      if (!collection) throw new Error("Colección no declarada");
      const graph = demoGraph(records, installed);
      if (collection.relation) return graphPage(graph, graph.edges.filter((edge) => edge.kind === "relation" && edge.ontologyId === ontologyId && edge.table === table), page) as T;
      const found = records.filter((record) => record.ontologyId === ontologyId && record.table === table);
      return { nodes: found.slice(page * demoPageSize, (page + 1) * demoPageSize).map((record) => graph.nodes.find((node) => node.key === graphKey(record.ontologyId, record.id))), edges: [], page, hasMore: (page + 1) * demoPageSize < found.length } as T;
    }
    if (method === "knowledge_graph_expand") {
      const ontologyId = String(params.ontologyId);
      const recordId = String(params.recordId);
      const page = Number(params.page ?? 0);
      const root = graphKey(ontologyId, recordId);
      const graph = demoGraph(records, installed);
      if (!graph.nodes.some((node) => node.key === root)) {
        const record = records.find((item) => item.ontologyId === ontologyId && item.id === recordId);
        if (!record) throw new Error("El registro ya no existe");
        const collection = installed.find((item) => item.id === ontologyId)?.collections.find((item) => item.table === record.table);
        graph.nodes.push({ key: root, ontologyId, recordId, table: record.table, label: String(record.values[collection?.titleField ?? ""] ?? recordId), missing: false });
      }
      const adjacent = graph.edges.filter((edge) => edge.source === root || edge.target === root);
      return graphPage(graph, adjacent, page, root) as T;
    }
    if (method === "knowledge_graph_detail") {
      const record = records.find((item) => item.ontologyId === params.ontologyId && item.id === params.recordId);
      if (!record) throw new Error("El registro ya no existe");
      return { ...record, truncatedFields: [] } as T;
    }
    if (method === "knowledge_save") {
      const prior = records.find((record) => record.id === params.recordId);
      if (prior && prior.rev !== params.expectedRev) throw new Error("El registro cambió mientras lo editabas. Copia tus cambios y vuelve a cargarlo.");
      const saved: KnowledgeRecord = { id: prior?.id ?? `${String(params.table)}:${crypto.randomUUID()}`, ontologyId: String(params.id), table: String(params.table), values: params.values as Record<string, unknown>, recordingId: prior?.recordingId ?? recordingId, versionId: prior?.versionId, rev: String(Number(prior?.rev ?? 0) + 1) };
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
