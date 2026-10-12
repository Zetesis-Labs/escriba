import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { call } from "../api";
import { Pane } from "../app/Pane";
import { Button, Toggle } from "../mac/controls";
import type { LogEntry } from "../types";
import "./log.css";

export function LogPane() {
  return (
    <Pane title="Registro">
      <div className="log-pane">
        <AppLog />
      </div>
    </Pane>
  );
}

const stamp = (value: string) => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const two = (number: number) => String(number).padStart(2, "0");
  return `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())} ${two(date.getHours())}:${two(date.getMinutes())}:${two(date.getSeconds())}`;
};

export const logPlainText = (lines: LogEntry[]) => lines.map((line) => `${stamp(line.at)} ${line.message}`).join("\n");

function useAppLog() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [problem, setProblem] = useState<string | null>(null);
  useEffect(() => {
    let current = true;
    let pending: Promise<unknown> = Promise.resolve();
    const load = () => {
      pending = pending.then(() =>
        call<LogEntry[]>("log_list", {})
          .then((lines) => {
            if (!current) return;
            setLogs(lines);
            setProblem(null);
          })
          .catch((error) => current && setProblem(error instanceof Error ? error.message : String(error))),
      );
    };
    load();
    const stops = ["escriba://log", "escriba://changed"].map((event) => listen(event, load));
    return () => {
      current = false;
      for (const stop of stops) void stop.then((unlisten) => unlisten());
    };
  }, []);
  return { logs, problem };
}

function AppLog() {
  const { logs, problem } = useAppLog();
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
      {problem && <div className="warning log-problem">{problem}</div>}
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
