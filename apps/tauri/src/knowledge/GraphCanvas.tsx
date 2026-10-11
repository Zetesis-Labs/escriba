import { Maximize2, Minus, Plus } from "lucide-react";
import { useCallback, useEffect, useRef } from "react";
import { edgeGeometry, fitGraph, hitEdge, type Camera } from "../core/graphGeometry";
import { graphBounds, layoutGraph, NODE_HEIGHT, NODE_WIDTH, type GraphPoint } from "../core/graphLayout";
import type { GraphData, GraphEdge, GraphNode, GraphSelection } from "./graphTypes";
import "./graphCanvas.css";

export type GraphCanvasProps = {
  graph: GraphData;
  mode: "schema" | "data";
  selection: GraphSelection;
  onSelect: (selection: GraphSelection) => void;
  onExpand?: (node: GraphNode) => void;
};

type Gesture = { pointer: number; x: number; y: number; moved: boolean; nodeKey?: string };
const clamp = (value: number) => Math.min(2.5, Math.max(.18, value));
const ontologyName = (id: string) => id === "escriba" ? "Escriba" : (id.split(".").at(-1) ?? id).replace(/^./, (letter) => letter.toUpperCase());

function ontologySlot(id: string): number {
  let hash = 0;
  for (const letter of id) hash = (hash * 31 + letter.charCodeAt(0)) >>> 0;
  return hash % 4;
}

function ontologyColor(id: string, colors: ReturnType<typeof readColors>): string {
  return id === "escriba" ? colors.blue : [colors.accent, colors.green, colors.orange, colors.pink][ontologySlot(id)];
}

function readColors(element: HTMLElement) {
  const style = getComputedStyle(element);
  const color = (name: string, fallback: string) => style.getPropertyValue(name).trim() || fallback;
  return {
    background: color("--content", "#f9f9f9"), surface: color("--control", "#fff"), label: color("--label", "#222"), secondary: color("--secondary", "#777"),
    separator: color("--separator", "#bbb"), accent: color("--accent", "#e8792a"), fill: color("--fill", "#eee"),
    blue: color("--blue", "#007aff"), green: color("--green", "#28a35b"), orange: color("--orange", "#ec8500"), pink: "#b56991",
  };
}

function roundedRect(context: CanvasRenderingContext2D, x: number, y: number, width: number, height: number, radius: number) {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
}

function clippedText(context: CanvasRenderingContext2D, value: string, width: number) {
  if (context.measureText(value).width <= width) return value;
  let end = value.length;
  while (end > 0 && context.measureText(`${value.slice(0, end)}…`).width > width) end--;
  return `${value.slice(0, end)}…`;
}

function edgeLabel(context: CanvasRenderingContext2D, edge: GraphEdge, scale: number) {
  context.font = `${Math.min(17, Math.max(11, 9.5 / scale))}px -apple-system, BlinkMacSystemFont, sans-serif`;
  const text = clippedText(context, edge.label || edge.table, 160);
  return { text, width: context.measureText(text).width + 16 };
}

export function GraphCanvas({ graph, mode, selection, onSelect, onExpand }: GraphCanvasProps) {
  const frameRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const positionsRef = useRef(new Map<string, GraphPoint>());
  const cameraRef = useRef<Camera>({ x: 0, y: 0, scale: 1 });
  const sizeRef = useRef({ width: 0, height: 0 });
  const frameId = useRef<number | null>(null);
  const gestureRef = useRef<Gesture | null>(null);
  const modeRef = useRef(mode);
  const graphRef = useRef(graph);
  const selectionRef = useRef(selection);
  const onSelectRef = useRef(onSelect);
  const onExpandRef = useRef(onExpand);
  graphRef.current = graph;
  selectionRef.current = selection;
  onSelectRef.current = onSelect;
  onExpandRef.current = onExpand;

  const draw = useCallback(() => {
    frameId.current = null;
    const canvas = canvasRef.current;
    const frame = frameRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !frame || !context) return;
    const { width, height } = sizeRef.current;
    if (!width || !height) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    const pixelWidth = Math.round(width * dpr);
    const pixelHeight = Math.round(height * dpr);
    if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) { canvas.width = pixelWidth; canvas.height = pixelHeight; }
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    const colors = readColors(frame);
    context.fillStyle = colors.background;
    context.fillRect(0, 0, width, height);
    context.fillStyle = colors.separator;
    context.globalAlpha = .28;
    for (let gridX = 18; gridX < width; gridX += 28) for (let gridY = 18; gridY < height; gridY += 28) context.fillRect(gridX, gridY, 1, 1);
    context.globalAlpha = 1;
    const { x, y, scale } = cameraRef.current;
    context.translate(x, y);
    context.scale(scale, scale);
    const positions = positionsRef.current;
    const current = graphRef.current;
    const selected = selectionRef.current;
    const visible = { left: -x / scale - 200, right: (width - x) / scale + 200, top: -y / scale - 150, bottom: (height - y) / scale + 150 };
    for (const edge of current.edges) {
      const curve = edgeGeometry(edge, positions, current.edges);
      if (!curve) continue;
      const active = selected?.kind === "edge" && selected.key === edge.key;
      context.beginPath();
      context.moveTo(curve.start.x, curve.start.y);
      context.bezierCurveTo(curve.control1.x, curve.control1.y, curve.control2.x, curve.control2.y, curve.end.x, curve.end.y);
      context.strokeStyle = active ? colors.accent : colors.label;
      context.globalAlpha = active ? .95 : edge.kind === "relation" ? .52 : .42;
      context.lineWidth = (active ? 2.4 : 1.7) / Math.max(.7, scale);
      context.setLineDash(edge.kind === "relation" ? [] : edge.kind === "reference" ? [6, 5] : [2, 5]);
      context.stroke();
      context.setLineDash([]);
      context.beginPath();
      context.moveTo(curve.end.x, curve.end.y);
      context.lineTo(curve.end.x - 8 * Math.cos(curve.arrowAngle - .5), curve.end.y - 8 * Math.sin(curve.arrowAngle - .5));
      context.lineTo(curve.end.x - 8 * Math.cos(curve.arrowAngle + .5), curve.end.y - 8 * Math.sin(curve.arrowAngle + .5));
      context.closePath();
      context.fillStyle = active ? colors.accent : colors.label;
      context.fill();
      context.globalAlpha = 1;
      if (curve.label.x < visible.left || curve.label.x > visible.right || curve.label.y < visible.top || curve.label.y > visible.bottom) continue;
      const label = edgeLabel(context, edge, scale);
      roundedRect(context, curve.label.x - label.width / 2, curve.label.y - 11, label.width, 22, 7);
      context.fillStyle = colors.background;
      context.fill();
      context.strokeStyle = active ? colors.accent : colors.secondary;
      context.globalAlpha = active ? .85 : .58;
      context.stroke();
      context.globalAlpha = 1;
      context.textAlign = "center";
      context.textBaseline = "middle";
      context.fillStyle = active ? colors.accent : colors.label;
      context.fillText(label.text, curve.label.x, curve.label.y + .5);
    }
    for (const node of current.nodes) {
      const point = positions.get(node.key);
      if (!point || point.x < visible.left || point.x > visible.right || point.y < visible.top || point.y > visible.bottom) continue;
      const active = selected?.kind === "node" && selected.key === node.key;
      const left = point.x - NODE_WIDTH / 2;
      const top = point.y - NODE_HEIGHT / 2;
      context.shadowColor = "#00000018";
      context.shadowBlur = active ? 14 : 8;
      context.shadowOffsetY = 2;
      roundedRect(context, left, top, NODE_WIDTH, NODE_HEIGHT, 10);
      context.fillStyle = colors.surface;
      context.fill();
      context.shadowColor = "transparent";
      context.strokeStyle = active ? colors.accent : colors.secondary;
      context.lineWidth = active ? 2 : 1;
      context.globalAlpha = active ? 1 : .55;
      if (node.missing) context.setLineDash([4, 3]);
      context.stroke();
      context.globalAlpha = 1;
      context.setLineDash([]);
      roundedRect(context, left + 8, top + 11, 3, NODE_HEIGHT - 22, 2);
      context.fillStyle = node.missing ? colors.secondary : ontologyColor(node.ontologyId, colors);
      context.globalAlpha = active ? 1 : .82;
      context.fill();
      context.globalAlpha = 1;
      context.textAlign = "left";
      context.textBaseline = "alphabetic";
      context.font = `600 ${Math.min(18, Math.max(12, 10 / scale))}px -apple-system, BlinkMacSystemFont, sans-serif`;
      context.fillStyle = colors.label;
      context.fillText(clippedText(context, node.label, NODE_WIDTH - 33), left + 20, top + 25);
      context.font = `${Math.min(15, Math.max(10, 8 / scale))}px -apple-system, BlinkMacSystemFont, sans-serif`;
      context.fillStyle = colors.secondary;
      const subtitle = node.ontologyId === "escriba" ? node.table : `${ontologyName(node.ontologyId)} · ${node.table}`;
      context.fillText(clippedText(context, node.missing ? `${subtitle} · no disponible` : subtitle, NODE_WIDTH - 33), left + 20, top + 43);
    }
  }, []);

  const schedule = useCallback(() => { if (frameId.current === null) frameId.current = requestAnimationFrame(draw); }, [draw]);
  const fit = useCallback(() => {
    cameraRef.current = fitGraph(graphBounds(positionsRef.current), sizeRef.current.width, sizeRef.current.height);
    schedule();
  }, [schedule]);

  const reveal = useCallback((choice: Exclude<GraphSelection, null>) => {
    const point = choice.kind === "node"
      ? positionsRef.current.get(choice.key)
      : (() => { const edge = graphRef.current.edges.find((item) => item.key === choice.key); return edge ? edgeGeometry(edge, positionsRef.current, graphRef.current.edges)?.label : undefined; })();
    if (!point) return;
    const camera = cameraRef.current;
    const { width, height } = sizeRef.current;
    const screenX = point.x * camera.scale + camera.x;
    const screenY = point.y * camera.scale + camera.y;
    if (screenX < 80 || screenX > width - 80 || screenY < 65 || screenY > height - 65) {
      cameraRef.current = { ...camera, x: width / 2 - point.x * camera.scale, y: height / 2 - point.y * camera.scale };
      schedule();
    }
  }, [schedule]);

  useEffect(() => {
    const changedMode = modeRef.current !== mode;
    const prior = changedMode ? undefined : positionsRef.current;
    positionsRef.current = layoutGraph(graph, mode, prior);
    modeRef.current = mode;
    if (changedMode || !prior?.size) fit();
    else schedule();
  }, [graph, mode, fit, schedule]);

  useEffect(() => {
    const frame = frameRef.current;
    if (!frame) return;
    const resize = () => {
      const rect = frame.getBoundingClientRect();
      const old = sizeRef.current;
      sizeRef.current = { width: rect.width, height: rect.height };
      if (!old.width && rect.width) fit();
      else { if (selectionRef.current) reveal(selectionRef.current); schedule(); }
    };
    const observer = new ResizeObserver(resize);
    observer.observe(frame);
    resize();
    const theme = matchMedia("(prefers-color-scheme: dark)");
    theme.addEventListener("change", schedule);
    return () => { observer.disconnect(); theme.removeEventListener("change", schedule); if (frameId.current !== null) cancelAnimationFrame(frameId.current); frameId.current = null; };
  }, [fit, reveal, schedule]);

  useEffect(() => { if (selection) reveal(selection); schedule(); }, [selection, reveal, schedule]);

  const worldPoint = (clientX: number, clientY: number): GraphPoint => {
    const rect = canvasRef.current?.getBoundingClientRect();
    const camera = cameraRef.current;
    return { x: (clientX - (rect?.left ?? 0) - camera.x) / camera.scale, y: (clientY - (rect?.top ?? 0) - camera.y) / camera.scale };
  };

  const hit = (point: GraphPoint): GraphSelection => {
    for (const node of [...graphRef.current.nodes].reverse()) {
      const center = positionsRef.current.get(node.key);
      if (center && Math.abs(point.x - center.x) <= NODE_WIDTH / 2 && Math.abs(point.y - center.y) <= NODE_HEIGHT / 2) return { kind: "node", key: node.key };
    }
    const context = canvasRef.current?.getContext("2d");
    for (const edge of [...graphRef.current.edges].reverse()) {
      const curve = edgeGeometry(edge, positionsRef.current, graphRef.current.edges);
      const labelWidth = context ? edgeLabel(context, edge, cameraRef.current.scale).width : 0;
      if (curve && hitEdge(curve, point, 7 / cameraRef.current.scale, labelWidth)) return { kind: "edge", key: edge.key };
    }
    return null;
  };

  const zoom = useCallback((factor: number, x = sizeRef.current.width / 2, y = sizeRef.current.height / 2) => {
    const camera = cameraRef.current;
    const scale = clamp(camera.scale * factor);
    const ratio = scale / camera.scale;
    cameraRef.current = { x: x - (x - camera.x) * ratio, y: y - (y - camera.y) * ratio, scale };
    schedule();
  }, [schedule]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const handleWheel = (event: WheelEvent) => {
      event.preventDefault();
      const rect = canvas.getBoundingClientRect();
      zoom(Math.exp(-event.deltaY * .002), event.clientX - rect.left, event.clientY - rect.top);
    };
    canvas.addEventListener("wheel", handleWheel, { passive: false });
    return () => canvas.removeEventListener("wheel", handleWheel);
  }, [zoom]);

  return <div ref={frameRef} className="knowledge-graph-canvas">
    <canvas ref={canvasRef} aria-label={`Grafo de ${mode === "schema" ? "estructura" : "registros"}. ${graph.nodes.length} nodos y ${graph.edges.length} relaciones. Usa las flechas para recorrerlo, intro para ampliar y más o menos para cambiar la escala.`} tabIndex={0}
      onPointerDown={(event) => {
        if (event.button !== 0) return;
        event.currentTarget.setPointerCapture(event.pointerId);
        const choice = hit(worldPoint(event.clientX, event.clientY));
        gestureRef.current = { pointer: event.pointerId, x: event.clientX, y: event.clientY, moved: false, nodeKey: choice?.kind === "node" ? choice.key : undefined };
        event.currentTarget.style.cursor = choice?.kind === "node" ? "grabbing" : "move";
      }}
      onPointerMove={(event) => {
        const gesture = gestureRef.current;
        if (!gesture || gesture.pointer !== event.pointerId) { event.currentTarget.style.cursor = hit(worldPoint(event.clientX, event.clientY)) ? "pointer" : "grab"; return; }
        const dx = event.clientX - gesture.x;
        const dy = event.clientY - gesture.y;
        if (Math.abs(dx) + Math.abs(dy) > 2) gesture.moved = true;
        if (gesture.moved && gesture.nodeKey) {
          const point = positionsRef.current.get(gesture.nodeKey);
          if (point) positionsRef.current.set(gesture.nodeKey, { x: point.x + dx / cameraRef.current.scale, y: point.y + dy / cameraRef.current.scale });
        } else if (gesture.moved) {
          cameraRef.current = { ...cameraRef.current, x: cameraRef.current.x + dx, y: cameraRef.current.y + dy };
        }
        gesture.x = event.clientX;
        gesture.y = event.clientY;
        schedule();
      }}
      onPointerUp={(event) => {
        const gesture = gestureRef.current;
        if (gesture?.pointer !== event.pointerId) return;
        if (!gesture.moved) onSelectRef.current(hit(worldPoint(event.clientX, event.clientY)));
        gestureRef.current = null;
        event.currentTarget.style.cursor = "grab";
        event.currentTarget.releasePointerCapture(event.pointerId);
      }}
      onPointerCancel={(event) => { gestureRef.current = null; event.currentTarget.style.cursor = "grab"; }}
      onDoubleClick={(event) => { const choice = hit(worldPoint(event.clientX, event.clientY)); if (choice?.kind === "node") { const node = graphRef.current.nodes.find((item) => item.key === choice.key); if (node) onExpandRef.current?.(node); } }}
      onKeyDown={(event) => {
        const entries: Exclude<GraphSelection, null>[] = [...graph.nodes.map((node) => ({ kind: "node" as const, key: node.key })), ...graph.edges.map((edge) => ({ kind: "edge" as const, key: edge.key }))];
        if (["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"].includes(event.key) && entries.length) {
          event.preventDefault();
          const index = entries.findIndex((item) => item.kind === selection?.kind && item.key === selection.key);
          const direction = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : -1;
          const next = entries[index < 0 ? direction > 0 ? 0 : entries.length - 1 : (index + direction + entries.length) % entries.length];
          onSelectRef.current(next);
          reveal(next);
        } else if (event.key === "Enter" && selection?.kind === "node") {
          const node = graph.nodes.find((item) => item.key === selection.key);
          if (node) onExpandRef.current?.(node);
        } else if (event.key === "Escape") onSelectRef.current(null);
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
    <div className="knowledge-graph-legend" aria-label="Colores de ontologías">{[...new Set(graph.nodes.map((node) => node.ontologyId))].map((id) => <span key={id}><i style={{ background: id === "escriba" ? "var(--blue)" : ["var(--accent)", "var(--green)", "var(--orange)", "#b56991"][ontologySlot(id)] }} />{ontologyName(id)}</span>)}</div>
    {!graph.nodes.length && <div className="knowledge-graph-empty">No hay elementos que mostrar.</div>}
    <div className="knowledge-graph-accessible" aria-live="polite">{selection?.kind === "node" ? `Nodo seleccionado: ${graph.nodes.find((node) => node.key === selection.key)?.label ?? ""}` : selection?.kind === "edge" ? `Relación seleccionada: ${graph.edges.find((edge) => edge.key === selection.key)?.label ?? ""}` : "Ningún elemento seleccionado"}</div>
  </div>;
}
