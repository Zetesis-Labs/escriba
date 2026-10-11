import { describe, expect, it } from "vitest";
import { edgeGeometry, hitEdge, fitGraph } from "../../src/core/graphGeometry";
import { NODE_HEIGHT, NODE_WIDTH } from "../../src/core/graphLayout";
import type { GraphEdge } from "../../src/knowledge/graphTypes";

const edge = (key: string, source = "a", target = "b"): GraphEdge => ({ key, source, target, label: key, kind: "relation", ontologyId: "escriba", table: "rel" });
const points = new Map([["a", { x: 0, y: 0 }], ["b", { x: 300, y: 0 }]]);

describe("graph geometry", () => {
  it("gives parallel links distinct readable lanes and hit areas", () => {
    const edges = [edge("first"), edge("second")];
    const first = edgeGeometry(edges[0], points, edges);
    const second = edgeGeometry(edges[1], points, edges);
    expect(first?.label.y).not.toBe(second?.label.y);
    expect(first && hitEdge(first, first.label, 7)).toBe(true);
    expect(second && hitEdge(second, second.label, 7)).toBe(true);
  });

  it("separates opposite directions between the same nodes", () => {
    const edges = [edge("forward"), edge("backward", "b", "a")];
    const forward = edgeGeometry(edges[0], points, edges);
    const backward = edgeGeometry(edges[1], points, edges);
    expect(forward?.label.y).not.toBe(backward?.label.y);
  });

  it("draws a finite selectable self relation", () => {
    const self = edgeGeometry(edge("self", "a", "a"), points, [edge("self", "a", "a")]);
    expect(self?.label.x).toBeGreaterThan(0);
    expect(self && hitEdge(self, self.label, 7)).toBe(true);
  });

  it("places multiple self-loop labels on separate sides of the node", () => {
    const edges = [edge("self-a", "a", "a"), edge("self-b", "a", "a")];
    const first = edgeGeometry(edges[0], points, edges);
    const second = edgeGeometry(edges[1], points, edges);
    expect(Math.hypot((first?.label.x ?? 0) - (second?.label.x ?? 0), (first?.label.y ?? 0) - (second?.label.y ?? 0))).toBeGreaterThan(70);
  });

  it("attaches self-loop arrows to the rectangular node in every orientation", () => {
    const edges = Array.from({ length: 4 }, (_, index) => edge(`self-${index}`, "a", "a"));
    for (const edgeItem of edges) {
      const curve = edgeGeometry(edgeItem, points, edges);
      for (const point of [curve?.start, curve?.end]) {
        expect(point).toBeDefined();
        expect(Math.abs(point!.x)).toBeLessThanOrEqual(NODE_WIDTH / 2 + .001);
        expect(Math.abs(point!.y)).toBeLessThanOrEqual(NODE_HEIGHT / 2 + .001);
        expect(Math.abs(Math.abs(point!.x) - NODE_WIDTH / 2) < .001 || Math.abs(Math.abs(point!.y) - NODE_HEIGHT / 2) < .001).toBe(true);
      }
    }
  });

  it("selects the visible ends of a long relation label", () => {
    const curve = edgeGeometry(edge("long"), points, [edge("long")]);
    expect(curve && hitEdge(curve, { x: curve.label.x + 66, y: curve.label.y }, 2, 150)).toBe(true);
  });

  it("does not generate invalid coordinates for absent endpoints or zero-size viewport", () => {
    expect(edgeGeometry(edge("missing", "a", "z"), points, [])).toBeNull();
    expect(fitGraph({ x: 0, y: 0, width: 0, height: 0 }, 0, 0)).toEqual({ x: 0, y: 0, scale: 1 });
  });
});
