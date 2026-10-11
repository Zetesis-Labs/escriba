import type { ElkNode } from "elkjs/lib/elk-api";
import type { GraphData } from "../knowledge/graphTypes";
import { NODE_HEIGHT, NODE_WIDTH, type GraphBounds, type GraphPoint } from "./graphLayout";

export type GraphLabel = GraphBounds & { text: string };
export type RoutedEdge = { points: GraphPoint[]; label: GraphLabel };
export type GraphScene = { positions: Map<string, GraphPoint>; edges: Map<string, RoutedEdge>; bounds: GraphBounds };
type MeasuredLabel = { text: string; width: number; height: number };

function coordinate(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) throw new Error("El motor del grafo devolvió una posición inválida.");
  return value;
}

export async function layoutScene(
  graph: GraphData,
  labels: ReadonlyMap<string, MeasuredLabel>,
  layout: (input: ElkNode) => Promise<ElkNode>,
  options: { direction?: "RIGHT" | "DOWN"; positions?: ReadonlyMap<string, GraphPoint> } = {},
): Promise<GraphScene> {
  const direction = options.direction ?? "DOWN";
  const nodes = [...graph.nodes];
  // Las posiciones previas orientan el orden; ELK vuelve a colocar todo para reservar espacio.
  if (options.positions) nodes.sort((a, b) => {
    const first = options.positions?.get(a.key), second = options.positions?.get(b.key);
    const axis = direction === "DOWN" ? "x" : "y";
    return (first?.[axis] ?? 0) - (second?.[axis] ?? 0) || a.key.localeCompare(b.key);
  });
  const input: ElkNode = {
    id: "scene",
    layoutOptions: {
      "elk.algorithm": "layered", "elk.direction": direction, "elk.edgeRouting": "ORTHOGONAL",
      "elk.padding": "[top=32,left=32,bottom=32,right=32]",
      "elk.spacing.nodeNode": "48", "elk.spacing.edgeNode": "20", "elk.spacing.edgeEdge": "16",
      "elk.spacing.edgeLabel": "12", "elk.spacing.labelNode": "12", "elk.spacing.labelLabel": "12",
      "elk.layered.spacing.nodeNodeBetweenLayers": "32", "elk.layered.spacing.edgeNodeBetweenLayers": "18",
      "elk.layered.spacing.edgeEdgeBetweenLayers": "16", "elk.layered.mergeEdges": "false",
      "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
    },
    children: nodes.map((node) => ({ id: node.key, width: NODE_WIDTH, height: NODE_HEIGHT })),
    edges: graph.edges.map((edge) => {
      const label = labels.get(edge.key);
      if (!label || !Number.isFinite(label.width) || !Number.isFinite(label.height) || label.width <= 0 || label.height <= 0) throw new Error(`Falta la medida de la relación ${edge.key}.`);
      return { id: edge.key, sources: [edge.source], targets: [edge.target], labels: [{ id: `label:${edge.key}`, ...label, layoutOptions: { "elk.edgeLabels.placement": "CENTER" } }] };
    }),
  };
  const output = await layout(input);
  const positions = new Map<string, GraphPoint>();
  const edges = new Map<string, RoutedEdge>();
  const boxes: GraphBounds[] = [];
  for (const node of output.children ?? []) {
    const x = coordinate(node.x), y = coordinate(node.y);
    positions.set(node.id, { x: x + NODE_WIDTH / 2, y: y + NODE_HEIGHT / 2 });
    boxes.push({ x, y, width: NODE_WIDTH, height: NODE_HEIGHT });
  }
  for (const edge of output.edges ?? []) {
    const section = edge.sections?.[0];
    const label = edge.labels?.[0];
    const measured = labels.get(edge.id);
    if (!section || edge.sections?.length !== 1 || !label || !measured) throw new Error(`El motor no pudo trazar la relación ${edge.id}.`);
    const points = [section.startPoint, ...(section.bendPoints ?? []), section.endPoint].map((point) => ({ x: coordinate(point.x), y: coordinate(point.y) }));
    const rectangle = { x: coordinate(label.x), y: coordinate(label.y), ...measured };
    edges.set(edge.id, { points, label: rectangle });
    boxes.push(rectangle, ...points.map((point) => ({ ...point, width: 0, height: 0 })));
  }
  if (positions.size !== graph.nodes.length || edges.size !== graph.edges.length || graph.nodes.some((node) => !positions.has(node.key)) || graph.edges.some((edge) => !edges.has(edge.key))) throw new Error("El motor devolvió un grafo incompleto.");
  const x = Math.min(...boxes.map((box) => box.x)), y = Math.min(...boxes.map((box) => box.y));
  const bounds = boxes.length ? { x, y, width: Math.max(...boxes.map((box) => box.x + box.width)) - x, height: Math.max(...boxes.map((box) => box.y + box.height)) - y } : { x: 0, y: 0, width: 0, height: 0 };
  return { positions, edges, bounds };
}
