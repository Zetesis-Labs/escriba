import { demoClientsOntology, demoOntology, demoKnowledgeHost } from "../knowledge/demo";
import type { OntologyDefinition } from "../knowledge/model";
import type { LibraryFilter, SavedLibraryFilter } from "../core/libraryFilters";

const base: OntologyDefinition = { id: "escriba", name: "Escriba", version: 1, builtIn: true, migrations: [], collections: [
  { table: "person", label: "Personas", titleField: "name", fields: [{ key: "name", label: "Nombre", type: "text" }] },
  { table: "recording", label: "Grabaciones", titleField: "title", fields: [{ key: "title", label: "Título", type: "text" }] },
  { table: "identified_as", label: "Asignado a persona", titleField: "id", fields: [], relation: { from: "speaker", to: "person" } },
] };
const knowledgeDemo = demoKnowledgeHost("demo-1");
let saved: SavedLibraryFilter[] = [{ id: "demo-saved", name: "Cliente Aurora", ontologyId: "demo.clientes", sql: "SELECT id FROM cliente WHERE nombre = 'Cliente Aurora'" }];

export async function demoFilterCommand<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (method === "knowledge_graph_roots" && params.ontologyId === "escriba" && (params.table === "person" || params.table === "recording")) {
    const entries = params.table === "person" ? [["person:ana", "Ana"], ["person:luis", "Luis"]] : [["recording:demo-1", "Reunión del lanzamiento"], ["recording:demo-2", "Ideas para el artículo"]];
    return { nodes: Number(params.page ?? 0) ? [] : entries.map(([recordId, label]) => ({ key: JSON.stringify(["escriba", recordId]), ontologyId: "escriba", table: params.table, recordId, label, missing: false })), edges: [], page: Number(params.page ?? 0), hasMore: false } as T;
  }
  if (method === "knowledge_graph_roots" || method === "knowledge_graph_detail") return knowledgeDemo<T>(method, params);
  if (method === "knowledge_list") return [base, demoClientsOntology, demoOntology] as T;
  if (method === "knowledge_filters_list") return [...saved] as T;
  if (method === "knowledge_filter_save") {
    const filter = params.filter as Omit<SavedLibraryFilter, "id"> & { id?: string };
    const result = { ...filter, id: filter.id ?? `demo-${Date.now()}` };
    saved = [...saved.filter((item) => item.id !== result.id), result];
    return result as T;
  }
  if (method === "knowledge_filter_remove") { saved = saved.filter((item) => item.id !== params.id); return undefined as T; }
  if (method === "knowledge_filter_notes") {
    const filter = params.filter as LibraryFilter;
    const content = filter.kind === "surrealql" ? filter.sql : JSON.stringify(filter.conditions);
    return { recordingIds: /sin resultados|ninguno|imposible/i.test(content) ? [] : /Aurora|aurora|reuniones|acuerdos|persona|Ana/.test(content) ? ["demo-1"] : ["demo-1", "demo-2"] } as T;
  }
  throw new Error(`Comando desconocido: ${method}`);
}
