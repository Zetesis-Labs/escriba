import type { GraphData, GraphEdge, GraphNode, GraphPage } from "../knowledge/graphTypes";
import type { OntologyDefinition } from "../knowledge/model";

export const schemaKey = (ontologyId: string, table: string) => JSON.stringify([ontologyId, table]);

export function schemaGraph(ontologies: OntologyDefinition[], scope?: string): GraphData {
  const nodes = new Map<string, GraphNode>();
  const edges: GraphEdge[] = [];
  const addNode = (ontologyId: string, table: string) => {
    const key = schemaKey(ontologyId, table);
    const collection = ontologies.find((ontology) => ontology.id === ontologyId)?.collections.find((item) => item.table === table);
    nodes.set(key, { key, ontologyId, table, recordId: table, label: collection?.label ?? table, missing: !collection });
    return key;
  };
  for (const ontology of ontologies.filter((item) => !scope || item.id === scope)) {
    for (const collection of ontology.collections) {
      if (collection.relation) {
        edges.push({ key: schemaKey(ontology.id, collection.table), source: addNode(ontology.id, collection.relation.from), target: addNode(ontology.id, collection.relation.to), label: collection.label, kind: "relation", ontologyId: ontology.id, table: collection.table });
      } else addNode(ontology.id, collection.table);
      for (const field of collection.fields) {
        if (!field.reference) continue;
        edges.push({ key: JSON.stringify([ontology.id, collection.table, field.key]), source: addNode(ontology.id, collection.table), target: addNode(field.reference.ontologyId, field.reference.table), label: field.label, kind: "reference", ontologyId: ontology.id, table: collection.table, field: field.key });
      }
    }
  }
  return { nodes: [...nodes.values()], edges };
}

export function mergeGraph(current: GraphData, added: GraphData, nodeLimit = 160): GraphData {
  const nodes = new Map(current.nodes.map((node) => [node.key, node]));
  const edges = new Map(current.edges.map((edge) => [edge.key, edge]));
  for (const node of added.nodes) nodes.set(node.key, node);
  for (const edge of added.edges) edges.set(edge.key, edge);
  if (nodes.size > nodeLimit || edges.size > 240) throw new Error("Este mapa ha alcanzado su límite de detalle. Centra el mapa en una entidad para seguir explorando sus conexiones.");
  return { nodes: [...nodes.values()], edges: [...edges.values()] };
}

function object(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isNode(value: unknown): value is GraphNode {
  return object(value) && ["key", "ontologyId", "table", "recordId", "label"].every((key) => typeof value[key] === "string") && typeof value.missing === "boolean";
}

function isEdge(value: unknown): value is GraphEdge {
  return object(value) && ["key", "source", "target", "label", "ontologyId", "table"].every((key) => typeof value[key] === "string") && ["relation", "reference", "provenance"].includes(String(value.kind)) && (value.recordId === undefined || typeof value.recordId === "string") && (value.field === undefined || typeof value.field === "string");
}

export function checkedGraphPage(value: unknown): GraphPage {
  if (object(value) && Array.isArray(value.nodes) && value.nodes.every(isNode) && Array.isArray(value.edges) && value.edges.every(isEdge) && typeof value.page === "number" && Number.isSafeInteger(value.page) && value.page >= 0 && typeof value.hasMore === "boolean" && (value.root === undefined || typeof value.root === "string")) {
    const keys = new Set(value.nodes.map((node) => node.key));
    if (keys.size === value.nodes.length && new Set(value.edges.map((edge) => edge.key)).size === value.edges.length && value.edges.every((edge) => keys.has(edge.source) && keys.has(edge.target)) && (value.root === undefined || keys.has(value.root))) {
      return { nodes: value.nodes, edges: value.edges, page: value.page, hasMore: value.hasMore, ...(typeof value.root === "string" ? { root: value.root } : {}) };
    }
  }
  throw new Error("La respuesta del mapa de conocimiento no es válida.");
}
