import ElkWorker from "elkjs/lib/elk-worker.min.js?worker";
import { Maximize2, Minus, Plus } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { fitGraph, hitRoute, zoomScale, type Camera } from "../core/graphGeometry";
import { NODE_HEIGHT, NODE_WIDTH, type GraphPoint } from "../core/graphLayout";
import { layoutScene, type GraphScene, type RoutedEdge } from "../core/graphScene";
import { errorText } from "../mac/native";
import type { GraphData, GraphNode, GraphSelection } from "./graphTypes";
import { graphWorker } from "./graphWorker";
import "./graphCanvas.css";

export type GraphCanvasProps = {
  graph: GraphData;
  mode: "schema" | "data";
  selection: GraphSelection;
  onSelect: (selection: GraphSelection) => void;
  onExpand?: (node: GraphNode) => void;
};

type Gesture = { pointer: number; x: number; y: number; moved: boolean; nodeKey?: string; preview?: GraphPoint };
const ontologyName = (id: string) => id === "escriba" ? "Escriba" : (id.split(".").at(-1) ?? id).replace(/^./, (letter) => letter.toUpperCase());

function ontologySlot(id: string): number {
  let hash = 0;
  for (const letter of id) hash = (hash * 31 + letter.charCodeAt(0)) >>> 0;
  return hash % 4;
}

function readColors(element: HTMLElement) {
  const style = getComputedStyle(element);
  const color = (name: string, fallback: string) => style.getPropertyValue(name).trim() || fallback;
  return {
    background: color("--content", "#f9f9f9"), surface: color("--control", "#fff"), label: color("--label", "#222"), secondary: color("--secondary", "#777"),
    separator: color("--separator", "#bbb"), accent: color("--accent", "#e8792a"),
    blue: color("--blue", "#007aff"), green: color("--green", "#28a35b"), orange: color("--orange", "#ec8500"), pink: "#b56991",
  };
}

function clippedText(context: CanvasRenderingContext2D, value: string, width: number) {
  if (context.measureText(value).width <= width) return value;
  let end = value.length;
  while (end > 0 && context.measureText(`${value.slice(0, end)}…`).width > width) end--;
  return `${value.slice(0, end)}…`;
}

function roundedRect(context: CanvasRenderingContext2D, x: number, y: number, width: number, height: number, radius: number) {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
}

function drawRoute(context: CanvasRenderingContext2D, route: RoutedEdge) {
  const points = route.points;
  if (points.length < 2) return;
  context.beginPath();
  context.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length - 1; i++) {
    const a = points[i - 1], b = points[i], c = points[i + 1];
    const before = Math.hypot(b.x - a.x, b.y - a.y), after = Math.hypot(c.x - b.x, c.y - b.y);
    const radius = Math.min(7, before / 2, after / 2);
    if (!radius) { context.lineTo(b.x, b.y); continue; }
    context.lineTo(b.x + (a.x - b.x) * radius / before, b.y + (a.y - b.y) * radius / before);
    context.quadraticCurveTo(b.x, b.y, b.x + (c.x - b.x) * radius / after, b.y + (c.y - b.y) * radius / after);
  }
  context.lineTo(points[points.length - 1].x, points[points.length - 1].y);
  context.stroke();
}

export function GraphCanvas({ graph, mode, selection, onSelect, onExpand }: GraphCanvasProps) {
  const frameRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const engineRef = useRef<ReturnType<typeof graphWorker> | null>(null);
  const sceneRef = useRef<GraphScene | null>(null);
  const cameraRef = useRef<Camera>({ x: 0, y: 0, scale: 1 });
  const autoFitRef = useRef(true);
  const sizeRef = useRef({ width: 0, height: 0 });
  const frameId = useRef<number | null>(null);
  const gestureRef = useRef<Gesture | null>(null);
  const generation = useRef(0);
  const graphRef = useRef(graph);
  const selectionRef = useRef(selection);
  const onSelectRef = useRef(onSelect);
  const onExpandRef = useRef(onExpand);
  const [layoutState, setLayoutState] = useState<"loading" | "ready">("loading");
  const [error, setError] = useState<string | null>(null);
  graphRef.current = graph;
  selectionRef.current = selection;
  onSelectRef.current = onSelect;
  onExpandRef.current = onExpand;

  const draw = useCallback(() => {
    frameId.current = null;
    const canvas = canvasRef.current, frame = frameRef.current, context = canvas?.getContext("2d");
    if (!canvas || !frame || !context) return;
    const { width, height } = sizeRef.current;
    if (!width || !height) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) { canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr); }
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    const colors = readColors(frame);
    context.fillStyle = colors.background;
    context.fillRect(0, 0, width, height);
    const scene = sceneRef.current;
    if (!scene) return;
    const { x, y, scale } = cameraRef.current;
    context.translate(x, y);
    context.scale(scale, scale);
    const current = graphRef.current, selected = selectionRef.current;
    for (const edge of current.edges) {
      const route = scene.edges.get(edge.key);
      if (!route) continue;
      const active = selected?.kind === "edge" && selected.key === edge.key;
      context.strokeStyle = active ? colors.accent : colors.secondary;
      context.globalAlpha = active ? 1 : .68;
      context.lineWidth = active ? 2.2 : 1.3;
      context.setLineDash(edge.kind === "relation" ? [] : edge.kind === "reference" ? [6, 5] : [2, 5]);
      drawRoute(context, route);
      context.setLineDash([]);
      const end = route.points.at(-1), before = route.points.at(-2);
      if (end && before) {
        const angle = Math.atan2(end.y - before.y, end.x - before.x);
        context.beginPath();
        context.moveTo(end.x, end.y);
        context.lineTo(end.x - 7 * Math.cos(angle - .45), end.y - 7 * Math.sin(angle - .45));
        context.lineTo(end.x - 7 * Math.cos(angle + .45), end.y - 7 * Math.sin(angle + .45));
        context.closePath();
        context.fillStyle = active ? colors.accent : colors.secondary;
        context.fill();
      }
      context.globalAlpha = 1;
    }
    for (const edge of current.edges) {
      const route = scene.edges.get(edge.key);
      if (!route) continue;
      const active = selected?.kind === "edge" && selected.key === edge.key;
      const label = route.label;
      roundedRect(context, label.x, label.y, label.width, label.height, 5);
      context.fillStyle = colors.background;
      context.fill();
      if (active) { context.strokeStyle = colors.accent; context.lineWidth = 1.2; context.stroke(); }
      context.font = "12px -apple-system, BlinkMacSystemFont, sans-serif";
      context.textAlign = "center";
      context.textBaseline = "middle";
      context.fillStyle = active ? colors.accent : colors.secondary;
      context.fillText(label.text, label.x + label.width / 2, label.y + label.height / 2);
    }
    for (const node of current.nodes) {
      const point = scene.positions.get(node.key);
      if (!point) continue;
      const active = selected?.kind === "node" && selected.key === node.key;
      const left = point.x - NODE_WIDTH / 2, top = point.y - NODE_HEIGHT / 2;
      context.shadowColor = "#00000010";
      context.shadowBlur = 5;
      context.shadowOffsetY = 2;
      roundedRect(context, left, top, NODE_WIDTH, NODE_HEIGHT, 9);
      context.fillStyle = colors.surface;
      context.fill();
      context.shadowColor = "transparent";
      context.strokeStyle = active ? colors.accent : colors.separator;
      context.lineWidth = active ? 2 : 1;
      if (node.missing) context.setLineDash([4, 3]);
      context.stroke();
      context.setLineDash([]);
      roundedRect(context, left + 9, top + 13, 3, NODE_HEIGHT - 26, 2);
      context.fillStyle = node.missing ? colors.secondary : node.ontologyId === "escriba" ? colors.blue : [colors.accent, colors.green, colors.orange, colors.pink][ontologySlot(node.ontologyId)];
      context.fill();
      context.textAlign = "left";
      context.textBaseline = "alphabetic";
      context.font = "600 13px -apple-system, BlinkMacSystemFont, sans-serif";
      context.fillStyle = colors.label;
      context.fillText(clippedText(context, node.label, NODE_WIDTH - 34), left + 22, top + 27);
      context.font = "11px -apple-system, BlinkMacSystemFont, sans-serif";
      context.fillStyle = colors.secondary;
      const subtitle = node.ontologyId === "escriba" ? node.table : `${ontologyName(node.ontologyId)} · ${node.table}`;
      context.fillText(clippedText(context, node.missing ? `${subtitle} · no disponible` : subtitle, NODE_WIDTH - 34), left + 22, top + 46);
    }
    const ghost = gestureRef.current?.preview;
    if (ghost && gestureRef.current?.moved) {
      roundedRect(context, ghost.x - NODE_WIDTH / 2, ghost.y - NODE_HEIGHT / 2, NODE_WIDTH, NODE_HEIGHT, 9);
      context.fillStyle = colors.accent; context.globalAlpha = .12; context.fill(); context.globalAlpha = 1;
      context.strokeStyle = colors.accent; context.lineWidth = 1.5; context.setLineDash([5, 4]); context.stroke(); context.setLineDash([]);
    }
  }, []);

  const schedule = useCallback(() => { if (frameId.current === null) frameId.current = requestAnimationFrame(draw); }, [draw]);
  const fit = useCallback(() => {
    if (sceneRef.current) cameraRef.current = fitGraph(sceneRef.current.bounds, sizeRef.current.width, sizeRef.current.height);
    autoFitRef.current = true;
    schedule();
  }, [schedule]);
  const arrange = useCallback(async (positions?: ReadonlyMap<string, GraphPoint>) => {
    const context = canvasRef.current?.getContext("2d");
    if (!context) return;
    const request = ++generation.current;
    setLayoutState("loading"); setError(null);
    context.font = "12px -apple-system, BlinkMacSystemFont, sans-serif";
    const labels = new Map(graphRef.current.edges.map((edge) => {
      const text = clippedText(context, edge.label || edge.table, 172);
      return [edge.key, { text, width: Math.ceil(context.measureText(text).width) + 16, height: 26 }];
    }));
    try {
      const engine = engineRef.current ?? graphWorker(new ElkWorker());
      engineRef.current = engine;
      const scene = await layoutScene(graphRef.current, labels, (input) => engine.layout(input), { direction: "DOWN", positions });
      if (request !== generation.current) return;
      sceneRef.current = scene;
      setLayoutState("ready"); fit();
    } catch (failure) { if (request === generation.current) { engineRef.current?.dispose(); engineRef.current = null; setError(errorText(failure)); setLayoutState("ready"); } }
  }, [fit]);

  useEffect(() => {
    return () => { generation.current++; engineRef.current?.dispose(); engineRef.current = null; };
  }, []);
  useEffect(() => { void arrange(); }, [graph, mode, arrange]);

  const reveal = useCallback((choice: Exclude<GraphSelection, null>) => {
    const scene = sceneRef.current;
    const label = choice.kind === "edge" ? scene?.edges.get(choice.key)?.label : undefined;
    const point = choice.kind === "node" ? scene?.positions.get(choice.key) : label ? { x: label.x + label.width / 2, y: label.y + label.height / 2 } : undefined;
    if (!point) return;
    const camera = cameraRef.current, { width, height } = sizeRef.current;
    const screenX = point.x * camera.scale + camera.x, screenY = point.y * camera.scale + camera.y;
    if (screenX < 90 || screenX > width - 90 || screenY < 65 || screenY > height - 65) {
      cameraRef.current = { ...camera, x: width / 2 - point.x * camera.scale, y: height / 2 - point.y * camera.scale };
      schedule();
    }
  }, [schedule]);

  useEffect(() => {
    const frame = frameRef.current;
    if (!frame) return;
    const resize = () => {
      const rect = frame.getBoundingClientRect(), old = sizeRef.current;
      sizeRef.current = { width: rect.width, height: rect.height };
      if (autoFitRef.current || !old.width) fit();
      else { cameraRef.current = { ...cameraRef.current, x: cameraRef.current.x + (rect.width - old.width) / 2, y: cameraRef.current.y + (rect.height - old.height) / 2 }; schedule(); }
    };
    const observer = new ResizeObserver(resize);
    observer.observe(frame); resize();
    const theme = matchMedia("(prefers-color-scheme: dark)");
    theme.addEventListener("change", schedule);
    return () => { observer.disconnect(); theme.removeEventListener("change", schedule); if (frameId.current !== null) cancelAnimationFrame(frameId.current); frameId.current = null; };
  }, [fit, schedule]);
  useEffect(() => { if (selection && !autoFitRef.current) reveal(selection); schedule(); }, [selection, reveal, schedule]);

  const worldPoint = (clientX: number, clientY: number): GraphPoint => {
    const rect = canvasRef.current?.getBoundingClientRect(), camera = cameraRef.current;
    return { x: (clientX - (rect?.left ?? 0) - camera.x) / camera.scale, y: (clientY - (rect?.top ?? 0) - camera.y) / camera.scale };
  };
  const hit = (point: GraphPoint): GraphSelection => {
    const scene = sceneRef.current;
    if (!scene) return null;
    for (const node of [...graphRef.current.nodes].reverse()) {
      const center = scene.positions.get(node.key);
      if (center && Math.abs(point.x - center.x) <= NODE_WIDTH / 2 && Math.abs(point.y - center.y) <= NODE_HEIGHT / 2) return { kind: "node", key: node.key };
    }
    for (const edge of [...graphRef.current.edges].reverse()) {
      const route = scene.edges.get(edge.key);
      if (route && hitRoute(route, point, 6 / cameraRef.current.scale)) return { kind: "edge", key: edge.key };
    }
    return null;
  };
  const zoom = useCallback((factor: number, x = sizeRef.current.width / 2, y = sizeRef.current.height / 2) => {
    const camera = cameraRef.current, scale = zoomScale(camera.scale, factor), ratio = scale / camera.scale;
    cameraRef.current = { x: x - (x - camera.x) * ratio, y: y - (y - camera.y) * ratio, scale };
    autoFitRef.current = false; schedule();
  }, [schedule]);
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const handleWheel = (event: WheelEvent) => { event.preventDefault(); const rect = canvas.getBoundingClientRect(); zoom(Math.exp(-event.deltaY * .002), event.clientX - rect.left, event.clientY - rect.top); };
    canvas.addEventListener("wheel", handleWheel, { passive: false });
    return () => canvas.removeEventListener("wheel", handleWheel);
  }, [zoom]);

  return <div ref={frameRef} className="knowledge-graph-canvas">
    <canvas ref={canvasRef} aria-label={`Grafo de ${mode === "schema" ? "estructura" : "registros"}. ${graph.nodes.length} nodos y ${graph.edges.length} relaciones. Usa las flechas para recorrerlo, intro para ampliar y más o menos para cambiar la escala.`} tabIndex={0}
      onPointerDown={(event) => {
        if (event.button !== 0 || layoutState === "loading") return;
        event.currentTarget.setPointerCapture(event.pointerId);
        const choice = hit(worldPoint(event.clientX, event.clientY));
        const nodeKey = choice?.kind === "node" ? choice.key : undefined;
        gestureRef.current = { pointer: event.pointerId, x: event.clientX, y: event.clientY, moved: false, nodeKey, preview: nodeKey ? sceneRef.current?.positions.get(nodeKey) : undefined };
        event.currentTarget.style.cursor = nodeKey ? "grabbing" : "move";
      }}
      onPointerMove={(event) => {
        const gesture = gestureRef.current;
        if (!gesture || gesture.pointer !== event.pointerId) { event.currentTarget.style.cursor = hit(worldPoint(event.clientX, event.clientY)) ? "pointer" : "grab"; return; }
        const dx = event.clientX - gesture.x, dy = event.clientY - gesture.y;
        if (Math.abs(dx) + Math.abs(dy) > 2) gesture.moved = true;
        if (gesture.moved && gesture.preview) gesture.preview = { x: gesture.preview.x + dx / cameraRef.current.scale, y: gesture.preview.y + dy / cameraRef.current.scale };
        else if (gesture.moved) { cameraRef.current = { ...cameraRef.current, x: cameraRef.current.x + dx, y: cameraRef.current.y + dy }; autoFitRef.current = false; }
        gesture.x = event.clientX; gesture.y = event.clientY; schedule();
      }}
      onPointerUp={(event) => {
        const gesture = gestureRef.current;
        if (gesture?.pointer !== event.pointerId) return;
        if (!gesture.moved) onSelectRef.current(hit(worldPoint(event.clientX, event.clientY)));
        else if (gesture.nodeKey && gesture.preview && sceneRef.current) { const positions = new Map(sceneRef.current.positions); positions.set(gesture.nodeKey, gesture.preview); void arrange(positions); }
        gestureRef.current = null; event.currentTarget.style.cursor = "grab"; event.currentTarget.releasePointerCapture(event.pointerId); schedule();
      }}
      onPointerCancel={(event) => { gestureRef.current = null; event.currentTarget.style.cursor = "grab"; schedule(); }}
      onDoubleClick={(event) => { const choice = hit(worldPoint(event.clientX, event.clientY)); if (choice?.kind === "node") { const node = graphRef.current.nodes.find((item) => item.key === choice.key); if (node) onExpandRef.current?.(node); } }}
      onKeyDown={(event) => {
        const entries: Exclude<GraphSelection, null>[] = [...graph.nodes.map((node) => ({ kind: "node" as const, key: node.key })), ...graph.edges.map((edge) => ({ kind: "edge" as const, key: edge.key }))];
        if (["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"].includes(event.key) && entries.length) {
          event.preventDefault();
          const index = entries.findIndex((item) => item.kind === selection?.kind && item.key === selection.key);
          const direction = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : -1;
          const next = entries[index < 0 ? direction > 0 ? 0 : entries.length - 1 : (index + direction + entries.length) % entries.length];
          onSelectRef.current(next); if (!autoFitRef.current) reveal(next);
        } else if (event.key === "Enter" && selection?.kind === "node") { const node = graph.nodes.find((item) => item.key === selection.key); if (node) onExpandRef.current?.(node); }
        else if (event.key === "Escape") onSelectRef.current(null);
        else if (event.key === "+" || event.key === "=") { event.preventDefault(); zoom(1.2); }
        else if (event.key === "-") { event.preventDefault(); zoom(1 / 1.2); }
        else if (event.key === "0") { event.preventDefault(); fit(); }
      }} />
    <div className="knowledge-graph-tools" role="group" aria-label="Vista del grafo">
      <button type="button" title="Acercar" aria-label="Acercar" onClick={() => zoom(1.2)}><Plus size={15} /></button>
      <button type="button" title="Alejar" aria-label="Alejar" onClick={() => zoom(1 / 1.2)}><Minus size={15} /></button>
      <span />
      <button type="button" title="Ajustar grafo" aria-label="Ajustar grafo" onClick={fit}><Maximize2 size={14} /></button>
    </div>
    {layoutState === "loading" && <div className="knowledge-graph-status" role="status">Ordenando el mapa…</div>}
    {error && <div className="knowledge-graph-status knowledge-error" role="alert">{error}<button onClick={() => void arrange()}>Reintentar</button></div>}
    <div className="knowledge-graph-legend" aria-label="Colores de ontologías">{[...new Set(graph.nodes.map((node) => node.ontologyId))].map((id) => <span key={id}><i style={{ background: id === "escriba" ? "var(--blue)" : ["var(--accent)", "var(--green)", "var(--orange)", "#b56991"][ontologySlot(id)] }} />{ontologyName(id)}</span>)}</div>
    <div className="knowledge-graph-accessible" aria-live="polite">{selection?.kind === "node" ? `Nodo seleccionado: ${graph.nodes.find((node) => node.key === selection.key)?.label ?? ""}` : selection?.kind === "edge" ? `Relación seleccionada: ${graph.edges.find((edge) => edge.key === selection.key)?.label ?? ""}` : "Ningún elemento seleccionado"}</div>
  </div>;
}
