import { ScrollText } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { call, desktop } from "../api";
import { Pane } from "../app/Pane";
import { displayTitle } from "../library/RecordingRow";
import { traceOutcome, traceText } from "../library/TraceCard";
import { Button, ContentUnavailable, PopupButton, Segmented, Toggle } from "../mac/controls";
import { RunRow } from "../recipes/RecipesPane";
import type { LogEntry, RecipeTrace, Snapshot } from "../types";
import "./log.css";

type Tab = "runs" | "app";
type Outcome = "all" | "ok" | "failed" | "waiting";

export function LogPane({ data }: { data: Snapshot }) {
  const [tab, setTab] = useState<Tab>("runs");
  return (
    <Pane title="Registro">
      <div className="log-pane">
        <div className="log-tabs">
          <Segmented
            value={tab}
            onChange={setTab}
            options={[
              { value: "runs", label: "Ejecuciones de recetas" },
              { value: "app", label: "Log de la app" },
            ]}
          />
        </div>
        <div className="detail-divider" />
        {tab === "runs" ? <RunsLog data={data} /> : <AppLog logs={data.logs} />}
      </div>
    </Pane>
  );
}

function RunsLog({ data }: { data: Snapshot }) {
  const [traces, setTraces] = useState<RecipeTrace[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [recipe, setRecipe] = useState("__");
  const [outcome, setOutcome] = useState<Outcome>("all");
  const [text, setText] = useState("");
  useEffect(() => {
    if (!desktop) return setTraces([]);
    let current = true;
    void call<RecipeTrace[]>("trace_list", {})
      .then((all) => current && setTraces(all))
      .catch((error) => current && setProblem(error instanceof Error ? error.message : String(error)));
    return () => {
      current = false;
    };
  }, [data]);
  const titles = useMemo(() => new Map(data.recordings.map((recording) => [recording.id, displayTitle(recording)])), [data.recordings]);
  const recipeName = (id?: string) => data.recipes.find((item) => item.id === id)?.name ?? id ?? "";
  const since = Date.now() - 30 * 86_400_000;
  const query = text.trim().toLocaleLowerCase("es");
  const runs = (traces ?? [])
    .filter((trace) => new Date(trace.startedAt).getTime() >= since)
    .filter((trace) => recipe === "__" || trace.recipeId === recipe)
    .filter((trace) => outcome === "all" || traceOutcome(trace) === outcome)
    .filter((trace) => !query || `${titles.get(trace.recordingId) ?? ""}\n${traceText(trace)}`.toLocaleLowerCase("es").includes(query))
    .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
    .slice(0, 300);
  return (
    <div className="log-body">
      <div className="log-filters">
        <PopupButton
          label="Receta"
          value={recipe}
          options={[{ value: "__", label: "Todas" }, ...data.recipes.map((item) => ({ value: item.id, label: item.name }))]}
          onChange={setRecipe}
        />
        <Segmented
          value={outcome}
          onChange={setOutcome}
          options={[
            { value: "all", label: "Todas" },
            { value: "ok", label: "Bien" },
            { value: "failed", label: "Falló" },
            { value: "waiting", label: "Esperando" },
          ]}
        />
        <input className="text-field selectable log-search" value={text} placeholder="Buscar en la nota o en el log" onChange={(event) => setText(event.target.value)} />
      </div>
      <div className="detail-divider" />
      {problem && <div className="warning log-problem">{problem}</div>}
      {traces && runs.length === 0 ? (
        <ContentUnavailable title="Sin ejecuciones" icon={ScrollText} description="Aquí sale cada vez que una receta procesa una nota, de los últimos 30 días." />
      ) : (
        <div className="log-list">
          {runs.map((trace) => (
            <div className="log-run" key={trace.id}>
              <RunRow trace={trace} title={titles.get(trace.recordingId) ?? trace.recordingId} recipeName={recipeName(trace.recipeId)} showsRecipe />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

const stamp = (value: string) => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const two = (number: number) => String(number).padStart(2, "0");
  return `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())} ${two(date.getHours())}:${two(date.getMinutes())}:${two(date.getSeconds())}`;
};

export const logPlainText = (lines: LogEntry[]) => lines.map((line) => `${stamp(line.at)} ${line.message}`).join("\n");

function AppLog({ logs }: { logs: LogEntry[] }) {
  const [text, setText] = useState("");
  const [onlyErrors, setOnlyErrors] = useState(false);
  const query = text.trim().toLocaleLowerCase("es");
  const visible = logs
    .filter((line) => (!onlyErrors || line.level === "error") && (!query || line.message.toLocaleLowerCase("es").includes(query)))
    .sort((a, b) => a.at.localeCompare(b.at));
  return (
    <div className="log-body">
      <div className="log-filters">
        <input className="text-field selectable log-search" value={text} placeholder="Filtrar" onChange={(event) => setText(event.target.value)} />
        <label className="log-toggle">
          <Toggle label="Solo errores" checked={onlyErrors} onChange={setOnlyErrors} /> Solo errores
        </label>
        <Button onClick={() => void navigator.clipboard.writeText(logPlainText(visible))} title="Copia las líneas que se ven, con el filtro aplicado">
          Copiar
        </Button>
      </div>
      <div className="detail-divider" />
      <pre className="app-log selectable">
        {visible.map((line) => (
          <div key={line.id} className={`log-line ${line.level}`}>
            <span className="tertiary">{stamp(line.at)} </span>
            {line.message}
          </div>
        ))}
      </pre>
    </div>
  );
}
