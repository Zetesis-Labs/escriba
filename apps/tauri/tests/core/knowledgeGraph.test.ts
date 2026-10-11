import { describe, expect, test } from "vitest";
import { schemaGraph, mergeGraph, checkedGraphPage, schemaKey } from "../../src/core/knowledgeGraph";
import type { InstalledOntology } from "../../src/knowledge/model";

const ontologies: InstalledOntology[] = [
  { id: "escriba", name: "Escriba", version: 1, builtIn: true, migrations: [], collections: [{ table: "person", label: "Personas", titleField: "name", fields: [] }] },
  { id: "crm", name: "Clientes", version: 1, migrations: [], collections: [
    { table: "person", label: "Contactos", titleField: "name", fields: [{ key: "original", label: "Persona", type: "reference", reference: { ontologyId: "escriba", table: "person" } }] },
    { table: "knows", label: "Conoce a", titleField: "name", fields: [], relation: { from: "person", to: "person" } },
    { table: "works_with", label: "Trabaja con", titleField: "name", fields: [], relation: { from: "person", to: "person" } },
  ] },
];

describe("mapas de conocimiento", () => {
  test("distingue las identidades de cada ontología y conserva dirección y relaciones paralelas", () => {
    const graph = schemaGraph(ontologies);
    expect(graph.nodes.map((node) => node.key)).toEqual([schemaKey("escriba", "person"), schemaKey("crm", "person")]);
    expect(graph.edges.map(({ label, source, target }) => ({ label, source, target }))).toEqual([
      { label: "Persona", source: schemaKey("crm", "person"), target: schemaKey("escriba", "person") },
      { label: "Conoce a", source: schemaKey("crm", "person"), target: schemaKey("crm", "person") },
      { label: "Trabaja con", source: schemaKey("crm", "person"), target: schemaKey("crm", "person") },
    ]);
    expect(new Set(graph.edges.map((edge) => edge.key)).size).toBe(3);
  });
  test("acotar una extensión conserva sus referencias a la base sin traer las demás colecciones", () => {
    const graph = schemaGraph(ontologies, "crm");
    expect(graph.nodes).toHaveLength(2);
    expect(graph.edges).toHaveLength(3);
    expect(schemaGraph(ontologies, "escriba").nodes).toHaveLength(1);
  });
  test("expandir conserva conexiones distintas y actualiza nodos que vuelven a estar disponibles", () => {
    const graph = schemaGraph(ontologies);
    const missing = { ...graph.nodes[0], missing: true };
    const merged = mergeGraph({ nodes: [missing], edges: [] }, graph);
    expect(merged).toEqual(graph);
    expect(mergeGraph(merged, graph)).toEqual(graph);
    expect(() => mergeGraph({ nodes: [], edges: [] }, graph, 1)).toThrow("Centra");
  });
  test("rechaza páginas malformadas o con aristas sin extremos en vez de mostrar un mapa incompleto", () => {
    const page = { ...schemaGraph(ontologies), page: 0, hasMore: false };
    expect(checkedGraphPage(page)).toEqual(page);
    expect(() => checkedGraphPage({ ...page, page: -1 })).toThrow("no es válida");
    expect(() => checkedGraphPage({ ...page, nodes: [] })).toThrow("no es válida");
    expect(() => checkedGraphPage({ ...page, edges: [{ ...page.edges[0], kind: "unknown" }] })).toThrow("no es válida");
    expect(() => checkedGraphPage({ ...page, nodes: [...page.nodes, page.nodes[0]] })).toThrow("no es válida");
  });
});
