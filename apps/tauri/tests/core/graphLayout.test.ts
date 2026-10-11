import { describe, expect, it } from "vitest";
import { layoutGraph, graphBounds } from "../../src/core/graphLayout";
import type { GraphData } from "../../src/knowledge/graphTypes";

const node = (key: string, table = "persona") => ({ key, ontologyId: "escriba", table, recordId: key, label: key, missing: false });
const edge = (key: string, source: string, target: string) => ({ key, source, target, label: key, kind: "relation" as const, ontologyId: "escriba", table: "conoce" });

describe("layoutGraph", () => {
  it("places a cyclic schema deterministically regardless of input order", () => {
    const graph: GraphData = { nodes: [node("a"), node("b"), node("c")], edges: [edge("ab", "a", "b"), edge("bc", "b", "c"), edge("ca", "c", "a")] };
    const first = layoutGraph(graph, "schema");
    const reversed = layoutGraph({ nodes: [...graph.nodes].reverse(), edges: [...graph.edges].reverse() }, "schema");
    expect([...first]).toEqual([...reversed]);
    expect(new Set([...first.values()].map((point) => `${point.x},${point.y}`)).size).toBe(3);
  });

  it("keeps existing positions while adding adjacent data", () => {
    const first = layoutGraph({ nodes: [node("a"), node("b")], edges: [edge("ab", "a", "b")] }, "data");
    const next = layoutGraph({ nodes: [node("a"), node("b"), node("c")], edges: [edge("ab", "a", "b"), edge("bc", "b", "c")] }, "data", first);
    expect(next.get("a")).toEqual(first.get("a"));
    expect(next.get("b")).toEqual(first.get("b"));
    expect(Number.isFinite(next.get("c")?.x)).toBe(true);
  });

  it("returns safe bounds for empty and singleton graphs", () => {
    expect(graphBounds(new Map())).toEqual({ x: 0, y: 0, width: 0, height: 0 });
    const one = layoutGraph({ nodes: [node("a")], edges: [] }, "data");
    const bounds = graphBounds(one);
    expect(bounds.width).toBeGreaterThan(0);
    expect(bounds.height).toBeGreaterThan(0);
  });

  it("uses the height of the canvas for long schema chains", () => {
    const nodes = Array.from({ length: 10 }, (_, index) => node(`n${index}`));
    const edges = nodes.slice(1).map((item, index) => edge(`e${index}`, nodes[index].key, item.key));
    const bounds = graphBounds(layoutGraph({ nodes, edges }, "schema"));
    expect(bounds.width / bounds.height).toBeLessThan(2.5);
  });
});
