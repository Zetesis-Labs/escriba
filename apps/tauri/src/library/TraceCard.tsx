import { AlertTriangle, CheckCircle2, ChevronRight, Clock, XCircle } from "lucide-react";
import { useState } from "react";
import { Button } from "../mac/controls";
import type { RecipeTrace } from "../types";

const seconds = new Intl.NumberFormat("es-ES", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

export function traceOutcome(trace: RecipeTrace) {
  if (!trace.error) return "ok" as const;
  return /BACKEND_UNAVAILABLE|RECIPE_UNAVAILABLE/.test(trace.error) ? ("waiting" as const) : ("failed" as const);
}

const outcomeLabel = { ok: "Bien", failed: "Falló", waiting: "Esperando" };
const stepTitle = (step: RecipeTrace["steps"][number]) => (step.origin ? `${step.capability} · ${step.origin}` : step.capability);
const elapsed = (trace: RecipeTrace) => (new Date(trace.finishedAt).getTime() - new Date(trace.startedAt).getTime()) / 1000;

export function traceHeadline(trace: RecipeTrace, recipeName?: string) {
  const parts = ["Cómo se procesó", recipeName ?? trace.recipeId, outcomeLabel[traceOutcome(trace)].toLowerCase()];
  const total = elapsed(trace);
  if (Number.isFinite(total)) parts.push(`${seconds.format(total)} s`);
  return parts.filter(Boolean).join(" · ");
}

export function traceText(trace: RecipeTrace, recipeName?: string) {
  const lines = [traceHeadline(trace, recipeName)];
  for (const step of trace.steps) {
    lines.push(`${step.error ? "✗" : "✓"} ${stepTitle(step)} · ${seconds.format(step.seconds)} s`);
    if (step.error) lines.push(`  ${step.error}`);
  }
  if (trace.error) lines.push(trace.error);
  return lines.join("\n");
}

export function TraceCard({ trace, recipeName }: { trace: RecipeTrace; recipeName?: string }) {
  const [expanded, setExpanded] = useState(false);
  const outcome = traceOutcome(trace);
  const Icon = outcome === "ok" ? CheckCircle2 : outcome === "waiting" ? Clock : AlertTriangle;
  return (
    <div className="trace-card">
      <button type="button" className={`trace-headline ${outcome === "ok" ? "secondary" : "warning"}`} onClick={() => setExpanded(!expanded)}>
        <ChevronRight size={12} strokeWidth={2.4} className={`disclosure ${expanded ? "open" : ""}`} />
        <Icon size={14} strokeWidth={1.8} />
        <span>{traceHeadline(trace, recipeName)}</span>
      </button>
      {expanded && (
        <div className="trace-detail">
          <div className="trace-copy">
            <Button small onClick={() => void navigator.clipboard.writeText(traceText(trace, recipeName))} title="Copia la traza entera como texto">
              Copiar
            </Button>
          </div>
          {trace.steps.map((step, index) => (
            <div className="trace-step" key={index}>
              <div className="trace-step-line">
                {step.error ? <XCircle size={13} className="warning" /> : <CheckCircle2 size={13} className="secondary" />}
                <span className="trace-step-title">{stepTitle(step)}</span>
                <span className="secondary monospaced-digits">{seconds.format(step.seconds)} s</span>
              </div>
              {step.error && <div className="font-caption secondary selectable">{step.error}</div>}
            </div>
          ))}
          {trace.error && <div className="font-caption warning selectable trace-error">{trace.error}</div>}
        </div>
      )}
    </div>
  );
}
