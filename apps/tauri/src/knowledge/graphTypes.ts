export type { EdgeKind } from "../generated/EdgeKind";
export type { GraphEdge } from "../generated/GraphEdge";
export type { GraphNode } from "../generated/GraphNode";
export type { GraphPage } from "../generated/GraphPage";
import type { GraphPage } from "../generated/GraphPage";

export type GraphSelection = { kind: "node" | "edge"; key: string } | null;
export type GraphData = Pick<GraphPage, "nodes" | "edges">;
