import type { GraphEdge } from "../knowledge/graphTypes";
import { NODE_HEIGHT, NODE_WIDTH, type GraphBounds, type GraphPoint } from "./graphLayout";

export type Camera = { x: number; y: number; scale: number };
export type EdgeGeometry = { start: GraphPoint; control1: GraphPoint; control2: GraphPoint; end: GraphPoint; label: GraphPoint; arrowAngle: number };

const pointOn = (curve: EdgeGeometry, t: number): GraphPoint => {
  const u = 1 - t;
  return {
    x: u ** 3 * curve.start.x + 3 * u ** 2 * t * curve.control1.x + 3 * u * t ** 2 * curve.control2.x + t ** 3 * curve.end.x,
    y: u ** 3 * curve.start.y + 3 * u ** 2 * t * curve.control1.y + 3 * u * t ** 2 * curve.control2.y + t ** 3 * curve.end.y,
  };
};

function nodeBoundary(center: GraphPoint, direction: GraphPoint): GraphPoint {
  const scale = Math.min((NODE_WIDTH / 2) / Math.max(Math.abs(direction.x), 0.001), (NODE_HEIGHT / 2) / Math.max(Math.abs(direction.y), 0.001));
  return { x: center.x + direction.x * scale, y: center.y + direction.y * scale };
}

export function edgeGeometry(edge: GraphEdge, positions: ReadonlyMap<string, GraphPoint>, edges: readonly GraphEdge[]): EdgeGeometry | null {
  const source = positions.get(edge.source);
  const target = positions.get(edge.target);
  if (!source || !target) return null;
  const siblings = edges.filter((item) => [item.source, item.target].sort().join("\0") === [edge.source, edge.target].sort().join("\0")).sort((a, b) => a.key.localeCompare(b.key));
  const index = Math.max(0, siblings.findIndex((item) => item.key === edge.key));
  const lane = index - (siblings.length - 1) / 2;
  if (edge.source === edge.target) {
    const spread = 48 + Math.floor(index / 4) * 26;
    const angle = -(index % 4) * Math.PI / 2;
    const rotate = (x: number, y: number): GraphPoint => ({ x: source.x + x * Math.cos(angle) - y * Math.sin(angle), y: source.y + x * Math.sin(angle) + y * Math.cos(angle) });
    const control2 = rotate(NODE_WIDTH / 2 + spread, -NODE_HEIGHT / 2 - spread);
    const startDirection = rotate(NODE_WIDTH / 2 - 12, 3);
    const endDirection = rotate(NODE_WIDTH / 2 - 20, -NODE_HEIGHT / 2);
    const end = nodeBoundary(source, { x: endDirection.x - source.x, y: endDirection.y - source.y });
    const curve: EdgeGeometry = {
      start: nodeBoundary(source, { x: startDirection.x - source.x, y: startDirection.y - source.y }),
      control1: rotate(NODE_WIDTH / 2 + spread, 44),
      control2,
      end,
      label: rotate(NODE_WIDTH / 2 + spread * .72, -spread * .28),
      arrowAngle: Math.atan2(end.y - control2.y, end.x - control2.x),
    };
    return curve;
  }
  const dx = target.x - source.x;
  const dy = target.y - source.y;
  const distance = Math.hypot(dx, dy) || 1;
  const direction = edge.source < edge.target ? 1 : -1;
  const normal = { x: (-dy / distance) * direction, y: (dx / distance) * direction };
  const offset = lane * 42;
  const start = nodeBoundary(source, { x: dx, y: dy });
  const end = nodeBoundary(target, { x: -dx, y: -dy });
  const control1 = { x: start.x + dx * .34 + normal.x * offset, y: start.y + dy * .34 + normal.y * offset };
  const control2 = { x: end.x - dx * .34 + normal.x * offset, y: end.y - dy * .34 + normal.y * offset };
  const curve: EdgeGeometry = { start, control1, control2, end, label: { x: 0, y: 0 }, arrowAngle: Math.atan2(end.y - control2.y, end.x - control2.x) };
  const midpoint = pointOn(curve, .5);
  curve.label = { x: midpoint.x + normal.x * (lane === 0 ? 13 : Math.sign(lane) * 13), y: midpoint.y + normal.y * (lane === 0 ? 13 : Math.sign(lane) * 13) };
  return curve;
}

export function hitEdge(curve: EdgeGeometry, point: GraphPoint, tolerance = 8, labelWidth = 0): boolean {
  if (labelWidth > 0 && Math.abs(point.x - curve.label.x) <= labelWidth / 2 + tolerance && Math.abs(point.y - curve.label.y) <= 11 + tolerance) return true;
  if (labelWidth <= 0 && Math.hypot(point.x - curve.label.x, point.y - curve.label.y) <= tolerance + 18) return true;
  for (let index = 0; index <= 30; index++) {
    const sample = pointOn(curve, index / 30);
    if (Math.hypot(point.x - sample.x, point.y - sample.y) <= tolerance) return true;
  }
  return false;
}

export function fitGraph(bounds: GraphBounds, width: number, height: number, padding = 44): Camera {
  if (width <= 0 || height <= 0 || bounds.width <= 0 || bounds.height <= 0) return { x: 0, y: 0, scale: 1 };
  const scale = Math.min(1.5, Math.max(.15, Math.min((width - padding * 2) / bounds.width, (height - padding * 2) / bounds.height)));
  return { x: width / 2 - (bounds.x + bounds.width / 2) * scale, y: height / 2 - (bounds.y + bounds.height / 2) * scale, scale };
}
