import { ArrowRight, CircleDot, GitBranch } from "lucide-react";
import { useEffect, useState } from "react";
import { knowledge } from "../api";
import type { GraphDetail } from "../generated/GraphDetail";
import { Spinner } from "../mac/controls";
import { errorText } from "../mac/native";
import type { GraphData, GraphEdge, GraphNode, GraphSelection } from "./graphTypes";
import { fieldText, type InstalledOntology } from "./model";

const fieldTypes: Record<string, string> = { text: "Texto", number: "Número", boolean: "Sí / no", date: "Fecha", json: "JSON", reference: "Referencia" };

export function GraphInspector({ mode, node, edge, graph, ontologies, onSelect }: { mode: "schema" | "data"; node?: GraphNode; edge?: GraphEdge; graph: GraphData; ontologies: InstalledOntology[]; onSelect: (selection: GraphSelection) => void }) {
  const item = node ?? edge;
  const ontology = ontologies.find((candidate) => candidate.id === item?.ontologyId);
  const collection = ontology?.collections.find((candidate) => candidate.table === item?.table);
  const [preview, setPreview] = useState<GraphDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const recordId = node?.recordId ?? edge?.recordId;
  const unavailable = !!node?.missing;

  useEffect(() => {
    let current = true;
    setPreview(null);
    setError(null);
    if (mode !== "data" || !recordId || !ontology || unavailable || edge?.kind === "provenance") return;
    setLoading(true);
    void knowledge("knowledge_graph_detail", { ontologyId: ontology.id, recordId }).then((result) => {
      if (current) setPreview(result);
    }).catch((failure) => { if (current) setError(errorText(failure)); }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [mode, ontology, recordId, unavailable, edge?.kind]);

  const endpoint = (key: string) => {
    const target = graph.nodes.find((candidate) => candidate.key === key);
    return <button className="graph-endpoint" onClick={() => onSelect({ kind: "node", key })}><CircleDot size={13} /><span>{target?.label ?? key}<small>{target?.table}</small></span><ArrowRight size={12} /></button>;
  };
  const connections = node ? graph.edges.filter((candidate) => candidate.source === node.key || candidate.target === node.key) : [];

  return <>
    <div className="graph-inspector-kind">{node ? "Entidad" : edge?.kind === "reference" ? "Referencia" : edge?.kind === "provenance" ? "Vínculo con una nota" : "Relación"}</div>
    <h3>{item?.label ?? "Selección"}</h3>
    <p className="graph-inspector-origin">{ontology?.name ?? item?.ontologyId}{ontology?.builtIn ? " · Base de Escriba" : " · Extensión"}</p>
    {item && <code className="graph-identity">{mode === "schema" ? item.table : recordId}</code>}
    {unavailable && <p className="graph-inspector-warning">El registro de destino ya no está disponible. La referencia se conserva.</p>}
    {edge && <section className="graph-inspector-section"><h4>Dirección</h4>{endpoint(edge.source)}<span className="graph-direction-label">{edge.label} →</span>{endpoint(edge.target)}</section>}
    {mode === "schema" && collection && <section className="graph-inspector-section"><h4>{edge?.field ? "Campo de referencia" : "Campos"}</h4>
      {collection.fields.length ? <dl className="graph-fields">{collection.fields.filter((field) => !edge?.field || field.key === edge.field).map((field) => <div key={field.key}><dt>{field.label}<code>{field.key}</code></dt><dd>{fieldTypes[field.type]}{field.required ? " · Obligatorio" : ""}{field.reference && <span>{field.reference.ontologyId} / {field.reference.table}</span>}</dd></div>)}</dl> : <p>Sin campos adicionales declarados.</p>}
    </section>}
    {mode === "data" && <section className="graph-inspector-section"><h4>Propiedades</h4>
      {loading && <div className="knowledge-loading"><Spinner /> Leyendo registro…</div>}
      {error && <p className="knowledge-error" role="alert">{error}</p>}
      {preview && <dl className="graph-fields">{collection?.fields.map((field) => <div key={field.key}><dt>{field.label}</dt><dd className="graph-value">{field.type === "boolean" && typeof preview.values[field.key] === "boolean" ? preview.values[field.key] ? "Sí" : "No" : fieldText(preview.values[field.key]) || "—"}{preview.truncatedFields?.includes(field.key) && <small>Vista previa recortada</small>}</dd></div>)}</dl>}
      {edge?.kind === "provenance" && <p>Vincula este registro a la versión de nota que lo utiliza.</p>}
      {!loading && !error && preview && !collection?.fields.length && <p>Sin campos adicionales declarados.</p>}
    </section>}
    {!!connections.length && <section className="graph-inspector-section"><h4>Conexiones {mode === "data" ? "visibles" : "declaradas"}</h4>{connections.map((connection) => <button key={connection.key} className="graph-connection" onClick={() => onSelect({ kind: "edge", key: connection.key })}><GitBranch size={13} /><span>{connection.label}<small>{graph.nodes.find((candidate) => candidate.key === (connection.source === node?.key ? connection.target : connection.source))?.label}</small></span><span>{connection.source === node?.key ? "→" : "←"}</span></button>)}</section>}
  </>;
}
