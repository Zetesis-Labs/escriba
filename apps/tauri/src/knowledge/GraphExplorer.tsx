import { ArrowLeft, ArrowRight, ChevronRight, CircleDot, GitBranch, Network, RotateCcw, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { knowledge } from "../api";
import { checkedGraphPage, mergeGraph, schemaGraph } from "../core/knowledgeGraph";
import { Button, Spinner } from "../mac/controls";
import { errorText } from "../mac/native";
import { GraphCanvas } from "./GraphCanvas";
import { GraphInspector } from "./GraphInspector";
import type { GraphData, GraphEdge, GraphNode, GraphPage, GraphSelection } from "./graphTypes";
import type { InstalledOntology } from "./model";
import "./graphExplorer.css";

const empty: GraphData = { nodes: [], edges: [] };
type Expansion = { page: number; hasMore: boolean };

export function GraphExplorer({ ontologies, mode }: { ontologies: InstalledOntology[]; mode: "schema" | "data" }) {
  const [ontologyId, setOntologyId] = useState(mode === "schema" ? "" : ontologies.find((item) => !item.builtIn)?.id ?? ontologies[0]?.id ?? "");
  const ontology = ontologies.find((item) => item.id === ontologyId);
  const [chosenTable, setChosenTable] = useState("");
  const table = ontology?.collections.find((item) => item.table === chosenTable)?.table ?? ontology?.collections.find((item) => !item.relation)?.table ?? ontology?.collections[0]?.table ?? "";
  const [page, setPage] = useState(0);
  const [roots, setRoots] = useState<GraphPage | null>(null);
  const [graph, setGraph] = useState<GraphData>(empty);
  const [selection, setSelection] = useState<GraphSelection>(null);
  const [expanded, setExpanded] = useState<Record<string, Expansion>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [rootKey, setRootKey] = useState("");
  const [reload, setReload] = useState(0);
  const [inspectorOpen, setInspectorOpen] = useState(false);
  const generation = useRef(0);
  const expanding = useRef(false);
  const latestGraph = useRef(graph);
  latestGraph.current = graph;

  const structure = useMemo(() => schemaGraph(ontologies, ontologyId || undefined), [ontologies, ontologyId]);
  const visible = mode === "schema" ? structure : graph;
  const selectedNode = selection?.kind === "node" ? visible.nodes.find((node) => node.key === selection.key) : undefined;
  const selectedEdge = selection?.kind === "edge" ? visible.edges.find((edge) => edge.key === selection.key) : undefined;
  const collection = ontology?.collections.find((item) => item.table === table);
  const rootNodes = roots?.nodes.filter((node) => node.ontologyId === ontologyId && node.table === table) ?? [];
  const rootEdges = roots?.edges.filter((edge) => edge.table === table && edge.ontologyId === ontologyId && edge.kind === "relation") ?? [];

  useEffect(() => {
    const request = ++generation.current;
    expanding.current = false;
    setSelection(null);
    setInspectorOpen(false);
    setError(null);
    setExpanded({});
    setRootKey("");
    setGraph(empty);
    setRoots(null);
    if (mode !== "data" || !ontologyId || !table) { setBusy(false); return; }
    setBusy(true);
    void knowledge("knowledge_graph_roots", { ontologyId, table, page }).then((result) => {
      if (request !== generation.current) return;
      const loaded = checkedGraphPage(result);
      setRoots(loaded);
      setGraph(loaded);
    }).catch((failure) => { if (request === generation.current) setError(errorText(failure)); }).finally(() => { if (request === generation.current) setBusy(false); });
    return () => { generation.current++; };
  }, [mode, ontologyId, table, page, reload]);

  const select = (next: GraphSelection) => { setSelection(next); setInspectorOpen(!!next); };

  const expand = async (node: GraphNode, center = false, relation?: GraphEdge) => {
    if (mode !== "data" || node.missing || expanding.current) return;
    const prior = center ? undefined : expanded[node.key];
    if (prior && !prior.hasMore) return;
    const request = center ? ++generation.current : generation.current;
    expanding.current = true;
    setBusy(true);
    setError(null);
    const relationEdge = relation ?? (selectedEdge?.kind === "relation" && selectedEdge.recordId === node.recordId && selectedEdge.ontologyId === node.ontologyId ? selectedEdge : undefined);
    const relationNodes = relationEdge ? [...latestGraph.current.nodes, ...(roots?.nodes ?? [])].filter((item) => item.key === relationEdge.source || item.key === relationEdge.target) : [];
    const seed = mergeGraph(empty, { nodes: [...relationNodes, node], edges: relationEdge ? [relationEdge] : [] });
    if (center) {
      setGraph(seed);
      setExpanded({});
      setRootKey(`${node.key}:${request}`);
      select(relationEdge ? { kind: "edge", key: relationEdge.key } : { kind: "node", key: node.key });
    }
    try {
      const loaded = checkedGraphPage(await knowledge("knowledge_graph_expand", { ontologyId: node.ontologyId, recordId: node.recordId, page: prior ? prior.page + 1 : 0 }));
      if (request !== generation.current) return;
      const merged = mergeGraph(center ? seed : latestGraph.current, loaded);
      setGraph(merged);
      setExpanded((current) => ({ ...(center ? {} : current), [loaded.root ?? node.key]: { page: loaded.page, hasMore: loaded.hasMore } }));
      if (center) setRootKey(`${loaded.root ?? node.key}:${request}:loaded`);
    } catch (failure) { if (request === generation.current) setError(errorText(failure)); }
    finally { if (request === generation.current) { expanding.current = false; setBusy(false); } }
  };

  const changeOntology = (id: string) => { generation.current++; setOntologyId(id); setChosenTable(""); setPage(0); };
  const changeTable = (value: string) => { generation.current++; setChosenTable(value); setPage(0); };
  const expandable = selectedNode ?? (selectedEdge?.kind === "relation" && selectedEdge.recordId ? { key: JSON.stringify([selectedEdge.ontologyId, selectedEdge.recordId]), ontologyId: selectedEdge.ontologyId, table: selectedEdge.table, recordId: selectedEdge.recordId, label: selectedEdge.label, missing: false } : undefined);
  const expansion = expandable ? expanded[expandable.key] : undefined;
  const selectRootEdge = (edge: GraphEdge) => {
    if (!edge.recordId) return;
    void expand({ key: JSON.stringify([edge.ontologyId, edge.recordId]), ontologyId: edge.ontologyId, table: edge.table, recordId: edge.recordId, label: edge.label, missing: false }, true, edge);
  };

  return <div className={`graph-explorer ${inspectorOpen ? "has-inspector" : ""}`}>
    <div className="graph-explorer-controls">
      <label>Ontología<select aria-label="Ontología del mapa" value={ontologyId} onChange={(event) => changeOntology(event.target.value)}>
        {mode === "schema" && <option value="">Todas las instaladas</option>}
        {ontologies.map((item) => <option key={item.id} value={item.id}>{item.name}{item.builtIn ? " · Base" : ""}</option>)}
      </select></label>
      {mode === "data" && <label>Colección<select aria-label="Colección del mapa" value={table} onChange={(event) => changeTable(event.target.value)}>{ontology?.collections.map((item) => <option key={item.table} value={item.table}>{item.label}{item.relation ? " · Relación" : ""}</option>)}</select></label>}
      <span className="graph-control-spacer" />
      {mode === "data" && <Button small icon={RotateCcw} disabled={busy} onClick={() => setReload((value) => value + 1)}>Reiniciar mapa</Button>}
    </div>
    {error && <div className="knowledge-error graph-message" role="alert">{error}</div>}
    <div className="graph-explorer-body">
      <aside className="graph-browser" aria-label={mode === "schema" ? "Entidades y relaciones" : "Registros de la colección"}>
        <div className="graph-browser-heading">{mode === "schema" ? "Entidades" : collection?.label ?? "Registros"}<span>{mode === "schema" ? structure.nodes.length : roots ? collection?.relation ? rootEdges.length : rootNodes.length : ""}</span></div>
        <div className="graph-browser-list">
          {mode === "schema" ? <>
            {structure.nodes.map((node) => <button key={node.key} className={`graph-browser-row ${selection?.kind === "node" && selection.key === node.key ? "selected" : ""}`} onClick={() => select({ kind: "node", key: node.key })}><CircleDot size={14} /><span>{node.label}<small>{ontologies.find((item) => item.id === node.ontologyId)?.name ?? node.ontologyId}</small></span></button>)}
            <div className="graph-browser-heading">Relaciones<span>{structure.edges.length}</span></div>
            {structure.edges.map((edge) => <button key={edge.key} className={`graph-browser-row ${selection?.kind === "edge" && selection.key === edge.key ? "selected" : ""}`} onClick={() => select({ kind: "edge", key: edge.key })}><GitBranch size={14} /><span>{edge.label}<small>{edge.kind === "reference" ? "Referencia" : edge.table}</small></span></button>)}
          </> : <>
            {busy && !roots && <div className="graph-browser-notice"><Spinner /> Cargando…</div>}
            {rootNodes.map((node) => <button key={node.key} disabled={busy} className={`graph-browser-row ${selection?.kind === "node" && selection.key === node.key ? "selected" : ""}`} onClick={() => void expand(node, true)}><CircleDot size={14} /><span>{node.label}</span><ChevronRight size={12} /></button>)}
            {rootEdges.map((edge) => <button key={edge.key} disabled={busy} className={`graph-browser-row ${selection?.kind === "edge" && selection.key === edge.key ? "selected" : ""}`} onClick={() => selectRootEdge(edge)}><GitBranch size={14} /><span>{edge.label}<small>{roots?.nodes.find((node) => node.key === edge.source)?.label} → {roots?.nodes.find((node) => node.key === edge.target)?.label}</small></span></button>)}
            {roots && !roots.nodes.length && <p className="graph-browser-notice">{page ? "No quedan registros en esta página." : "Esta colección aún no tiene registros."}</p>}
          </>}
        </div>
        {mode === "data" && <div className="graph-pagination"><Button small icon={ArrowLeft} title="Página anterior" disabled={busy || page === 0} onClick={() => setPage((value) => value - 1)} /><span>{page + 1}</span><Button small icon={ArrowRight} title="Página siguiente" disabled={busy || !roots?.hasMore} onClick={() => setPage((value) => value + 1)} /></div>}
      </aside>
      <div className="graph-workspace">
        {visible.nodes.length ? <GraphCanvas key={`${mode}:${ontologyId}:${table}:${page}:${rootKey}`} graph={visible} mode={mode} selection={selection} onSelect={select} onExpand={mode === "data" ? (node) => void expand(node) : undefined} /> : <div className="graph-empty"><Network size={36} strokeWidth={1.2} /><strong>{busy ? "Cargando el mapa…" : error ? "No se pudo cargar el mapa" : "Sin entidades que mostrar"}</strong><span>{error ? "Vuelve a intentarlo con Reiniciar mapa." : mode === "data" ? "Elige una colección con registros." : "Instala una ontología para explorar su estructura."}</span></div>}
        {busy && !!visible.nodes.length && <div className="graph-working" role="status"><Spinner /> Cargando conexiones…</div>}
      </div>
      {inspectorOpen && selection && <aside className="graph-inspector" aria-label="Inspector del mapa"><button className="graph-inspector-close" aria-label="Cerrar inspector" onClick={() => setInspectorOpen(false)}><X size={15} /></button>
        <GraphInspector key={`${selection.kind}:${selection.key}`} mode={mode} node={selectedNode} edge={selectedEdge} graph={visible} ontologies={ontologies} onSelect={select} />
        {mode === "data" && expandable && !expandable.missing && <div className="graph-inspector-actions"><Button small prominent disabled={busy || (expansion !== undefined && !expansion.hasMore)} onClick={() => void expand(expandable)}>{expansion ? expansion.hasMore ? "Más conexiones" : "Conexiones cargadas" : "Ver conexiones"}</Button><Button small disabled={busy} onClick={() => void expand(expandable, true)}>Centrar aquí</Button></div>}
      </aside>}
    </div>
    <footer className="graph-explorer-footer"><span>{visible.nodes.length} entidades · {visible.edges.length} conexiones{mode === "data" ? " en este mapa" : " declaradas"}</span><span>{mode === "schema" ? "Selecciona una entidad o una relación para inspeccionarla." : "Doble clic para desplegar conexiones · Solo lectura"}</span></footer>
  </div>;
}
