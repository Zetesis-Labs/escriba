import { AlertTriangle, CheckCircle2, ChevronRight, Clock, XCircle } from "lucide-react";
import { useState } from "react";
import { Button } from "../mac/controls";
import type { RecipeTrace } from "../types";
import "./trace.css";

const seconds = new Intl.NumberFormat("es-ES", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const capabilityNames: Record<string, string> = {
  transcribe: "Transcribir",
  summarize: "Resumir",
  save: "Guardar datos",
  ask: "Consultar",
  publish: "Publicar",
  "account.http": "Consultar cuenta",
  "graph.open": "Abrir conocimiento",
  "graph.query": "Consultar o guardar conocimiento",
  "graph.link": "Vincular conocimiento con la nota",
  process: "Ejecutar otra receta",
  log: "Registro",
};
const capabilityName = (value: string) => capabilityNames[value] ?? value;
const stepTitle = (step: RecipeTrace["steps"][number]) =>
  step.origin ? `${capabilityName(step.capability)} · ${step.origin}` : capabilityName(step.capability);
const elapsed = (trace: RecipeTrace) => (new Date(trace.finishedAt).getTime() - new Date(trace.startedAt).getTime()) / 1000;
const duration = (value: number) => `${seconds.format(value)} s`;
const resultLabels = (result: RecipeTrace["result"]) => {
  if (!result || typeof result !== "object" || Array.isArray(result)) return [];
  const labels: string[] = [];
  if (result.transcript != null) labels.push("Transcripción");
  if (result.digest != null) labels.push("Resumen");
  if (result.data != null) labels.push("Datos");
  return labels;
};

export function traceOutcome(trace: RecipeTrace) {
  if (!trace.error) return "ok" as const;
  if (trace.errorCode === undefined) {
    return /^(BACKEND_UNAVAILABLE|RECIPE_UNAVAILABLE):/.test(trace.error) ? ("waiting" as const) : ("failed" as const);
  }
  return ["backend_unavailable", "recipe_unavailable", "runtime_unavailable"].includes(trace.errorCode ?? "") ? ("waiting" as const) : ("failed" as const);
}

const outcomeLabel = { ok: "Completada", failed: "Falló", waiting: "En espera" };
const headlineLabel = { ok: "bien", failed: "falló", waiting: "esperando" };

export function traceHeadline(trace: RecipeTrace, recipeName?: string) {
  const parts = ["Cómo se procesó", recipeName ?? trace.recipeId, headlineLabel[traceOutcome(trace)]];
  const total = elapsed(trace);
  if (Number.isFinite(total)) parts.push(duration(total));
  return parts.filter(Boolean).join(" · ");
}

export function traceText(trace: RecipeTrace, recipeName?: string) {
  const lines = [traceHeadline(trace, recipeName)];
  if (trace.dryRun) lines.push("Prueba de receta");
  for (const step of trace.steps) {
    lines.push(`${step.error ? "✗" : "✓"} ${stepTitle(step)} · ${duration(step.seconds)}`);
    if (step.error) lines.push(`  ${step.error}`);
  }
  if (trace.error) lines.push(trace.error);
  if (trace.result !== undefined && trace.result !== null) lines.push("Resultado registrado", JSON.stringify(trace.result, null, 2));
  return lines.join("\n");
}

function StatusIcon({ outcome }: { outcome: ReturnType<typeof traceOutcome> }) {
  const Icon = outcome === "ok" ? CheckCircle2 : outcome === "waiting" ? Clock : AlertTriangle;
  return <Icon size={16} strokeWidth={1.8} aria-hidden="true" />;
}

export function TraceCard({ trace, recipeName }: { trace: RecipeTrace; recipeName?: string }) {
  const [expanded, setExpanded] = useState(false);
  const outcome = traceOutcome(trace);
  return (
    <section className={`recipe-trace recipe-trace-${outcome}`} aria-label="Proceso de la receta">
      <button type="button" className="recipe-trace-toggle" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
        <span className="recipe-trace-status"><StatusIcon outcome={outcome} /></span>
        <span className="recipe-trace-heading">
          <span className="recipe-trace-name">{recipeName ?? trace.recipeId ?? "Receta"}</span>
          <span className="recipe-trace-meta">{outcomeLabel[outcome]}{trace.dryRun ? " · Prueba" : ""} · {trace.steps.length} {trace.steps.length === 1 ? "paso" : "pasos"}</span>
        </span>
        {Number.isFinite(elapsed(trace)) && <span className="recipe-trace-time monospaced-digits">{duration(elapsed(trace))}</span>}
        <ChevronRight size={13} className={`disclosure ${expanded ? "open" : ""}`} aria-hidden="true" />
      </button>
      {expanded && <TraceDetail trace={trace} recipeName={recipeName} compact />}
    </section>
  );
}

export function TraceDetail({ trace, recipeName, compact = false }: { trace: RecipeTrace; recipeName?: string; compact?: boolean }) {
  const outcome = traceOutcome(trace);
  return (
    <div className="recipe-trace-detail">
      {!compact && (
        <div className="recipe-trace-detail-heading">
          <span className={`recipe-trace-status recipe-trace-${outcome}`}><StatusIcon outcome={outcome} /></span>
          <span className="recipe-trace-heading">
            <strong className="recipe-trace-name">{recipeName ?? trace.recipeId ?? "Receta"}</strong>
            <span className="recipe-trace-meta">{outcomeLabel[outcome]}{trace.dryRun ? " · Prueba" : ""}</span>
          </span>
          {Number.isFinite(elapsed(trace)) && <span className="recipe-trace-time monospaced-digits">{duration(elapsed(trace))}</span>}
        </div>
      )}
      <div className="recipe-trace-toolbar">
        <span className="font-caption secondary">{trace.steps.length} {trace.steps.length === 1 ? "paso registrado" : "pasos registrados"}</span>
        <Button small onClick={() => void navigator.clipboard.writeText(traceText(trace, recipeName))} title="Copia los pasos, errores y el resultado registrado">
          Copiar
        </Button>
      </div>
      {trace.steps.length > 0 ? (
        <ol className="recipe-trace-steps">
          {trace.steps.map((step, index) => (
            <li className={`recipe-trace-step ${step.error ? "recipe-trace-step-error" : ""}`} key={index}>
              <span className="recipe-trace-marker" aria-hidden="true">{step.error ? <XCircle size={15} /> : <CheckCircle2 size={15} />}</span>
              <div className="recipe-trace-step-body">
                <div className="recipe-trace-step-line">
                  <span className="recipe-trace-step-name">{capabilityName(step.capability)} <span className="recipe-trace-step-state">· {step.error ? "Falló" : "Hecho"}</span></span>
                  <span className="recipe-trace-step-time monospaced-digits">{duration(step.seconds)}</span>
                </div>
                {step.origin && <span className="recipe-trace-origin font-caption secondary">{step.origin}</span>}
                {step.error && <p className="recipe-trace-step-message selectable">{step.error}</p>}
                <details className="recipe-trace-technical">
                  <summary>Detalles técnicos</summary>
                  <dl>
                    <dt>Capacidad</dt><dd className="selectable">{step.capability}</dd>
                    {step.origin && <><dt>Origen</dt><dd className="selectable">{step.origin}</dd></>}
                    <dt>Duración</dt><dd className="monospaced-digits">{step.seconds} s</dd>
                  </dl>
                </details>
              </div>
            </li>
          ))}
        </ol>
      ) : <p className="recipe-trace-empty secondary">No se registraron pasos.</p>}
      {trace.error && <div className="recipe-trace-final-error" role="alert"><AlertTriangle size={15} aria-hidden="true" /><span className="selectable">{trace.error}</span></div>}
      {trace.result !== undefined && trace.result !== null && (
        <details className="recipe-trace-result">
          <summary>Resultado registrado{resultLabels(trace.result).length > 0 && <span className="recipe-trace-result-labels"> · {resultLabels(trace.result).join(" · ")}</span>}</summary>
          <pre className="selectable">{JSON.stringify(trace.result, null, 2)}</pre>
        </details>
      )}
    </div>
  );
}

export const traceSeconds = (trace: RecipeTrace) => elapsed(trace);
export const formatSeconds = (value: number) => seconds.format(value);
