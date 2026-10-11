import type { GraphData, GraphNode } from "../knowledge/graphTypes";

export type GraphPoint = { x: number; y: number };
export type GraphBounds = { x: number; y: number; width: number; height: number };
export const NODE_WIDTH = 154;
export const NODE_HEIGHT = 58;

const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));
const compare = (a: GraphNode, b: GraphNode) => a.label.localeCompare(b.label) || a.key.localeCompare(b.key);
const valid = (point: GraphPoint | undefined): point is GraphPoint => !!point && Number.isFinite(point.x) && Number.isFinite(point.y);

function clustered(nodes: readonly GraphNode[]): Map<string, GraphPoint> {
  const groups = new Map<string, GraphNode[]>();
  for (const node of nodes) {
    const group = groups.get(node.ontologyId) ?? [];
    group.push(node);
    groups.set(node.ontologyId, group);
  }
  const entries = [...groups].map(([key, group]) => [key, group.sort(compare)] as const)
    .sort(([a], [b]) => a.localeCompare(b));
  const columns = Math.max(1, Math.ceil(Math.sqrt(entries.length * 1.5)));
  const rows = Math.ceil(entries.length / columns);
  const points = new Map<string, GraphPoint>();
  const maxGroupSize = Math.max(...entries.map(([, group]) => group.length), 1);
  const rings = Math.ceil(Math.sqrt(maxGroupSize / 6));
  const cellWidth = Math.max(420, rings * 350);
  const cellHeight = Math.max(360, rings * 330);
  entries.forEach(([, group], groupIndex) => {
    const row = Math.floor(groupIndex / columns);
    const rowCount = Math.min(columns, entries.length - row * columns);
    const cx = ((groupIndex % columns) - (rowCount - 1) / 2) * cellWidth;
    const cy = (row - (rows - 1) / 2) * cellHeight;
    group.forEach((node, index) => {
      if (index === 0) { points.set(node.key, { x: cx, y: cy }); return; }
      const ring = Math.ceil((Math.sqrt(12 * index + 9) - 3) / 6);
      const prior = 3 * (ring - 1) * ring;
      const count = Math.min(6 * ring, group.length - 1 - prior);
      const offset = index - 1 - prior;
      const angle = -Math.PI / 2 + (Math.PI * 2 * offset) / Math.max(count, 1) + ring * GOLDEN_ANGLE;
      points.set(node.key, { x: cx + ring * 195 * Math.cos(angle), y: cy + ring * 145 * Math.sin(angle) });
    });
  });
  return points;
}

function schema(graph: GraphData): Map<string, GraphPoint> {
  const nodes = [...graph.nodes].sort(compare);
  const keys = new Set(nodes.map((node) => node.key));
  const predecessors = new Map(nodes.map((node) => [node.key, new Set<string>()]));
  for (const edge of graph.edges) if (edge.source !== edge.target && keys.has(edge.source) && keys.has(edge.target)) predecessors.get(edge.target)?.add(edge.source);
  const depth = new Map<string, number>();
  const remaining = new Set(nodes.map((node) => node.key));
  while (remaining.size) {
    const ready = [...remaining].filter((key) => [...(predecessors.get(key) ?? [])].every((source) => !remaining.has(source)));
    const batch = ready.length ? ready : [[...remaining].sort()[0]];
    for (const key of batch) {
      depth.set(key, Math.max(0, ...[...(predecessors.get(key) ?? [])].map((source) => (depth.get(source) ?? -1) + 1)));
      remaining.delete(key);
    }
  }
  const columns = new Map<number, GraphNode[]>();
  for (const node of nodes) {
    const column = depth.get(node.key) ?? 0;
    const group = columns.get(column) ?? [];
    group.push(node);
    columns.set(column, group);
  }
  const points = new Map<string, GraphPoint>();
  const columnCount = Math.max(1, Math.min(4, Math.ceil(Math.sqrt(nodes.length * 1.25))));
  const bandCount = Math.ceil((Math.max(...columns.keys(), 0) + 1) / columnCount);
  let bandCenter = 0;
  for (let band = 0; band < bandCount; band++) {
    const depths = Array.from({ length: columnCount }, (_, index) => band * columnCount + index);
    const rowSize = Math.max(1, ...depths.map((depthIndex) => columns.get(depthIndex)?.length ?? 0));
    for (const depthIndex of depths) {
      const group = columns.get(depthIndex) ?? [];
      const slot = depthIndex % columnCount;
      const column = band % 2 ? columnCount - 1 - slot : slot;
      group.forEach((node, index) => points.set(node.key, { x: column * 218, y: bandCenter + (index - (group.length - 1) / 2) * 106 }));
    }
    bandCenter += rowSize * 106 + 52;
  }
  return points;
}

export function layoutGraph(graph: GraphData, mode: "schema" | "data", previous?: ReadonlyMap<string, GraphPoint>): Map<string, GraphPoint> {
  const initial = mode === "schema" ? schema(graph) : clustered(graph.nodes);
  if (!previous?.size) return initial;
  const points = new Map<string, GraphPoint>();
  for (const node of graph.nodes) {
    const point = previous.get(node.key);
    if (valid(point)) points.set(node.key, point);
  }
  const incoming = new Map<string, string[]>();
  for (const edge of graph.edges) {
    incoming.set(edge.source, [...(incoming.get(edge.source) ?? []), edge.target]);
    incoming.set(edge.target, [...(incoming.get(edge.target) ?? []), edge.source]);
  }
  for (const node of [...graph.nodes].sort(compare)) {
    if (points.has(node.key)) continue;
    const neighbor = (incoming.get(node.key) ?? []).sort().map((key) => points.get(key)).find(valid);
    const center = neighbor ?? initial.get(node.key) ?? { x: 0, y: 0 };
    let candidate = center;
    for (let attempt = 0; attempt < 64; attempt++) {
      const angle = -Math.PI / 2 + attempt * GOLDEN_ANGLE;
      const radius = 190 + Math.floor(attempt / 8) * 60;
      candidate = { x: center.x + radius * Math.cos(angle), y: center.y + radius * Math.sin(angle) };
      if ([...points.values()].every((point) => Math.abs(point.x - candidate.x) > NODE_WIDTH + 22 || Math.abs(point.y - candidate.y) > NODE_HEIGHT + 30)) break;
    }
    points.set(node.key, candidate);
  }
  return points;
}

export function graphBounds(points: ReadonlyMap<string, GraphPoint>): GraphBounds {
  const values = [...points.values()].filter(valid);
  if (!values.length) return { x: 0, y: 0, width: 0, height: 0 };
  const minX = Math.min(...values.map((point) => point.x)) - NODE_WIDTH / 2;
  const maxX = Math.max(...values.map((point) => point.x)) + NODE_WIDTH / 2;
  const minY = Math.min(...values.map((point) => point.y)) - NODE_HEIGHT / 2;
  const maxY = Math.max(...values.map((point) => point.y)) + NODE_HEIGHT / 2;
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}
