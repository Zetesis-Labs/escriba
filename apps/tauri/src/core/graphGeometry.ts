import type { GraphBounds, GraphPoint } from "./graphLayout";
import type { RoutedEdge } from "./graphScene";

export type Camera = { x: number; y: number; scale: number };

export function zoomScale(current: number, factor: number): number {
  return Math.min(2.5, Math.max(Math.min(.12, current), current * factor));
}

export function hitRoute(route: RoutedEdge, point: GraphPoint, tolerance: number): boolean {
  const label = route.label;
  if (point.x >= label.x && point.x <= label.x + label.width && point.y >= label.y && point.y <= label.y + label.height) return true;
  for (let i = 1; i < route.points.length; i++) {
    const a = route.points[i - 1], b = route.points[i];
    const dx = b.x - a.x, dy = b.y - a.y;
    const length = dx * dx + dy * dy;
    const t = length ? Math.max(0, Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0;
    if (Math.hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= tolerance) return true;
  }
  return false;
}

export function fitGraph(bounds: GraphBounds, width: number, height: number, padding = 44): Camera {
  if (width <= 0 || height <= 0 || bounds.width <= 0 || bounds.height <= 0) return { x: 0, y: 0, scale: 1 };
  const scale = Math.min(1.2, Math.max(1, width - padding * 2) / bounds.width, Math.max(1, height - padding * 2) / bounds.height);
  return { x: width / 2 - (bounds.x + bounds.width / 2) * scale, y: height / 2 - (bounds.y + bounds.height / 2) * scale, scale };
}
