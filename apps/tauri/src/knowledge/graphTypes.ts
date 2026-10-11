export type GraphNode = {
  key: string;
  ontologyId: string;
  table: string;
  recordId: string;
  label: string;
  missing: boolean;
};

export type GraphEdge = {
  key: string;
  source: string;
  target: string;
  label: string;
  kind: "relation" | "reference" | "provenance";
  ontologyId: string;
  table: string;
  recordId?: string;
  field?: string;
};

export type GraphPage = {
  nodes: GraphNode[];
  edges: GraphEdge[];
  page: number;
  hasMore: boolean;
  root?: string;
};

export type GraphSelection = { kind: "node" | "edge"; key: string } | null;
export type GraphData = Pick<GraphPage, "nodes" | "edges">;
