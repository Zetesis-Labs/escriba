import { expect, test } from "vitest";
import ELK from "elkjs/lib/elk.bundled.js";
import { layoutScene, type GraphScene } from "../../src/core/graphScene";
import { NODE_HEIGHT, NODE_WIDTH, type GraphBounds } from "../../src/core/graphLayout";
import type { GraphData } from "../../src/knowledge/graphTypes";

const labels: Record<string, string> = { recording: "Grabaciones", version: "Versiones", transcript: "Transcripciones", segment: "Segmentos", word: "Palabras", speaker: "Hablantes", person: "Personas", cliente: "Clientes", contacto: "Contactos" };
export const topology: GraphData = {
  nodes: Object.entries(labels).map(([key, label]) => ({ key, label, ontologyId: key === "cliente" || key === "contacto" ? "clientes" : "escriba", recordId: key, table: key, missing: false })),
  edges: [
    ["has_version", "recording", "version", "Tiene versión"],
    ["has_transcript", "version", "transcript", "Tiene transcripción"],
    ["has_segment", "transcript", "segment", "Contiene segmento"],
    ["has_word", "segment", "word", "Contiene palabra"],
    ["spoken_by", "segment", "speaker", "Dicho por"],
    ["identified_as", "speaker", "person", "Asignado a persona"],
    ["derived_from", "version", "version", "Corregida desde"],
    ["reference", "contacto", "person", "Persona de Escriba"],
    ["pertenece_a", "contacto", "cliente", "Contactos de cada cliente"],
  ].map(([key, source, target, label]) => ({ key, source, target, label, kind: "relation", ontologyId: "escriba", table: key })),
};

const elk = new ELK();
const measured = (graph: GraphData) => new Map(graph.edges.map((edge) => [edge.key, { text: edge.label, width: Math.min(180, edge.label.length * 6.5 + 16), height: 24 }]));
const sceneFor = (graph = topology) => layoutScene(graph, measured(graph), (input) => elk.layout(input));
const overlaps = (a: GraphBounds, b: GraphBounds) => a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
const cards = (scene: GraphScene) => [...scene.positions].map(([key, center]) => ({ key, x: center.x - NODE_WIDTH / 2, y: center.y - NODE_HEIGHT / 2, width: NODE_WIDTH, height: NODE_HEIGHT }));

function checkRoutes(scene: GraphScene) {
  const collisions: string[] = [];
  for (const [key, edge] of scene.edges) {
    for (let i = 1; i < edge.points.length; i++) {
      const a = edge.points[i - 1], b = edge.points[i];
      expect(Math.min(Math.abs(a.x - b.x), Math.abs(a.y - b.y)), `${key}: ${JSON.stringify([a, b])}`).toBeLessThan(0.001);
      for (const card of cards(scene)) {
        const epsilon = 0.001;
        if (overlaps({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x) + epsilon, height: Math.abs(a.y - b.y) + epsilon }, { x: card.x + epsilon, y: card.y + epsilon, width: card.width - 2 * epsilon, height: card.height - 2 * epsilon })) collisions.push(`${key} atraviesa ${card.key}`);
      }
    }
  }
  expect(collisions).toEqual([]);
}

function checkLabels(scene: GraphScene) {
  const occupied: GraphBounds[] = cards(scene);
  for (const edge of scene.edges.values()) {
    expect(occupied.filter((box) => overlaps(box, edge.label))).toEqual([]);
    occupied.push(edge.label);
  }
}

test("las conexiones de la ontología no atraviesan entidades", async () => {
  checkRoutes(await sceneFor());
});

test("los nombres de relaciones no se montan sobre entidades ni entre sí", async () => {
  checkLabels(await sceneFor());
});

test("conserva rutas y nombres separados para ciclos, relaciones paralelas y varios bucles", async () => {
  const graph: GraphData = { nodes: topology.nodes, edges: [...topology.edges,
    ...Array.from({ length: 4 }, (_, index) => ({ ...topology.edges[0], key: `parallel-${index}`, label: `Otra relación extensa ${index}` })),
    ...Array.from({ length: 3 }, (_, index) => ({ ...topology.edges[6], key: `loop-${index}`, label: `Otra corrección ${index}` })),
    { ...topology.edges[0], key: "cycle", source: "word", target: "recording", label: "De vuelta a la grabación" },
  ] };
  const scene = await sceneFor(graph);
  expect(scene.edges.size).toBe(graph.edges.length);
  checkRoutes(scene);
  checkLabels(scene);
  const loop = scene.edges.get("derived_from")!;
  expect(new Set(loop.points.map((point) => `${point.x},${point.y}`)).size).toBeGreaterThan(3);
  expect(new Set(["has_version", "parallel-0", "parallel-1"].map((key) => JSON.stringify(scene.edges.get(key)!.points))).size).toBe(3);
});

test("encuadra tarjetas, etiquetas y todos los puntos de las conexiones", async () => {
  const scene = await sceneFor();
  const boxes = [...cards(scene), ...[...scene.edges.values()].flatMap((edge) => [edge.label, ...edge.points.map((point) => ({ ...point, width: 0, height: 0 }))])];
  for (const box of boxes) {
    expect(box.x).toBeGreaterThanOrEqual(scene.bounds.x);
    expect(box.y).toBeGreaterThanOrEqual(scene.bounds.y);
    expect(box.x + box.width).toBeLessThanOrEqual(scene.bounds.x + scene.bounds.width + 0.001);
    expect(box.y + box.height).toBeLessThanOrEqual(scene.bounds.y + scene.bounds.height + 0.001);
  }
});

test("reordena tarjetas arrastradas sin conservar posiciones que colisionan", async () => {
  const positions = new Map(topology.nodes.map((node, index) => [node.key, { x: index % 2, y: 0 }]));
  const scene = await layoutScene(topology, measured(topology), (input) => elk.layout(input), { positions });
  checkRoutes(scene);
  checkLabels(scene);
  const boxes = cards(scene);
  expect(boxes.flatMap((box, index) => boxes.slice(index + 1).filter((other) => overlaps(box, other)))).toEqual([]);
});

test("acepta un grafo vacío y rechaza una geometría incompleta del motor", async () => {
  expect(await sceneFor({ nodes: [], edges: [] })).toEqual({ positions: new Map(), edges: new Map(), bounds: { x: 0, y: 0, width: 0, height: 0 } });
  await expect(layoutScene(topology, measured(topology), async () => ({ id: "scene" }))).rejects.toThrow("incompleto");
});

test("no confunde una entidad y una relación que comparten identidad", async () => {
  const graph: GraphData = { nodes: topology.nodes.slice(0, 2), edges: [{ ...topology.edges[0], key: topology.nodes[0].key }] };
  const scene = await sceneFor(graph);
  expect([...scene.edges.keys()]).toEqual([topology.nodes[0].key]);
  expect([...scene.positions.keys()].sort()).toEqual(graph.nodes.map((node) => node.key).sort());
  checkRoutes(scene);
});

test("rechaza posiciones no finitas y nodos inesperados aunque coincida el recuento", async () => {
  const graph: GraphData = { nodes: topology.nodes.slice(0, 1), edges: [] };
  await expect(layoutScene(graph, new Map(), async () => ({ id: "scene", children: [{ id: graph.nodes[0].key, x: NaN, y: 0 }] }))).rejects.toThrow("inválida");
  await expect(layoutScene(graph, new Map(), async () => ({ id: "scene", children: [{ id: "extraño", x: 0, y: 0 }] }))).rejects.toThrow("incompleto");
});
