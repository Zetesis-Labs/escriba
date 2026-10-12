import { AlertTriangle, Ban, CheckCircle2, Clock, ListChecks, Loader } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Pane } from "../app/Pane";
import { activeOrder, appendPage, historyKinds, historyQuery, historyStates, jobActions, jobKind, jobStatus, jobTimes, refreshedHistory, type HistoryState } from "../core/jobs";
import type { HistoryCursor } from "../generated/HistoryCursor";
import type { Job } from "../generated/Job";
import type { RecipeRef } from "../generated/RecipeRef";
import { displayTitle } from "../library/RecordingRow";
import { Button, ContentUnavailable, PopupButton } from "../mac/controls";
import { alertMessage, errorText } from "../mac/native";
import { cancelProcessing, jobHistory } from "../runtime";
import type { Snapshot } from "../types";
import "./jobs.css";

function useNow(ticking: boolean) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    setNow(new Date());
    if (!ticking) return;
    const timer = window.setInterval(() => setNow(new Date()), 15_000);
    return () => window.clearInterval(timer);
  }, [ticking]);
  return now;
}

interface Loaded {
  filter: string;
  rows: Job[];
  next: HistoryCursor | null;
}

function useHistory(state: HistoryState, kind: string, activeKey: string) {
  const filter = `${state}\n${kind}`;
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [recipes, setRecipes] = useState<RecipeRef[]>([]);
  const [problem, setProblem] = useState<string | null>(null);
  const loading = useRef(false);
  const current = useRef(filter);
  current.current = filter;

  useEffect(() => {
    let alive = true;
    void jobHistory(historyQuery(state, kind, null))
      .then((page) => {
        if (!alive) return;
        setRecipes(page.recipes);
        setLoaded((previous) => ({ filter, ...(previous?.filter === filter ? refreshedHistory(previous.rows, previous.next, page) : { rows: page.jobs, next: page.next }) }));
        setProblem(null);
      })
      .catch((failure) => alive && setProblem(errorText(failure)));
    return () => {
      alive = false;
    };
  }, [state, kind, filter, activeKey]);

  const more = useCallback(() => {
    const before = loaded?.filter === filter ? loaded.next : null;
    if (!before || loading.current) return;
    loading.current = true;
    void jobHistory(historyQuery(state, kind, before))
      .then((page) => {
        if (current.current !== filter) return;
        setLoaded((previous) => (previous?.filter === filter ? { filter, rows: appendPage(previous.rows, page.jobs), next: page.next } : previous));
        setProblem(null);
      })
      .catch((failure) => setProblem(errorText(failure)))
      .finally(() => {
        loading.current = false;
      });
  }, [loaded, filter, state, kind]);

  const visible = loaded?.filter === filter ? loaded : null;
  return { rows: visible?.rows ?? null, hasMore: Boolean(visible?.next), recipes, problem, more };
}

function StateIcon({ job }: { job: Job }) {
  const props = { size: 14, strokeWidth: 1.8 };
  if (job.state === "running") return <Loader {...props} className="secondary" />;
  if (job.state === "queued" || job.state === "retry") return <Clock {...props} className="secondary" />;
  if (job.state === "succeeded") return <CheckCircle2 {...props} className="secondary" />;
  if (job.state === "cancelled") return <Ban {...props} className="secondary" />;
  return <AlertTriangle {...props} className="warning" />;
}

function JobRow({ job, title, kind, now, onOpen }: { job: Job; title: string; kind: string; now: Date; onOpen: () => void }) {
  const [expanded, setExpanded] = useState(false);
  const actions = jobActions(job);
  const times = jobTimes(job, now);
  const cancel = () => void cancelProcessing(job.recordingId).catch((failure) => alertMessage("Trabajos", errorText(failure)));
  return (
    <div className="job-row">
      <StateIcon job={job} />
      <div className="job-text">
        <div className="job-line">
          <span className="job-title">{title}</span>
          <span className="secondary">
            {" · "}
            {kind} · {jobStatus(job, now)}
          </span>
        </div>
        {times && <div className="font-caption secondary">{times}</div>}
        {actions.error && !expanded && <div className="font-caption job-error-line">{job.error}</div>}
        {expanded && (
          <pre className="job-error selectable">
            {job.error}
            {job.errorCode && `\n\nCódigo: ${job.errorCode}`}
          </pre>
        )}
      </div>
      <div className="job-actions">
        {actions.cancel && (
          <Button small onClick={cancel}>
            Cancelar
          </Button>
        )}
        {actions.error && (
          <Button small onClick={() => setExpanded(!expanded)}>
            {expanded ? "Ocultar error" : "Ver error"}
          </Button>
        )}
        <Button small onClick={onOpen}>
          Abrir nota
        </Button>
      </div>
    </div>
  );
}

export function JobsPane({ data, jobs, jobsProblem, onOpen }: { data: Snapshot; jobs: Job[]; jobsProblem: string | null; onOpen: (recordingId: string) => void }) {
  const [state, setState] = useState<HistoryState>("all");
  const [kind, setKind] = useState("all");
  const active = useMemo(() => activeOrder(jobs), [jobs]);
  const activeKey = useMemo(() => active.map((job) => `${job.id}:${job.state}`).join(","), [active]);
  const history = useHistory(state, kind, activeKey);
  const now = useNow(active.length > 0);
  const titles = useMemo(() => new Map(data.recordings.map((recording) => [recording.id, displayTitle(recording)])), [data.recordings]);
  const kinds = historyKinds(history.recipes);
  const scroller = useRef<HTMLDivElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  const { more, hasMore } = history;

  useEffect(() => {
    const target = sentinel.current;
    if (!target || !hasMore) return;
    const observer = new IntersectionObserver((entries) => entries.some((entry) => entry.isIntersecting) && more(), { root: scroller.current });
    observer.observe(target);
    return () => observer.disconnect();
  }, [more, hasMore]);

  const row = (job: Job) => (
    <JobRow key={job.id} job={job} title={titles.get(job.recordingId) ?? "Nota"} kind={jobKind(job, data.destinations)} now={now} onOpen={() => onOpen(job.recordingId)} />
  );
  const filtered = state !== "all" || kind !== "all";

  return (
    <Pane title="Trabajos">
      <div className="jobs-pane" ref={scroller}>
        <h2 className="jobs-heading">En marcha</h2>
        {jobsProblem ? (
          <div className="warning jobs-problem">{jobsProblem}</div>
        ) : active.length ? (
          <div className="jobs-list">{active.map(row)}</div>
        ) : (
          <div className="jobs-empty secondary">No hay nada en marcha.</div>
        )}
        <div className="jobs-history-header">
          <h2 className="jobs-heading">Historial</h2>
          <PopupButton label="Estado" value={state} options={historyStates} onChange={setState} />
          <PopupButton label="Receta" value={kinds.some((item) => item.value === kind) ? kind : "all"} options={kinds} onChange={setKind} />
        </div>
        {history.problem && <div className="warning jobs-problem">No se pudo leer el historial: {history.problem}</div>}
        {history.rows === null ? (
          !history.problem && <div className="jobs-empty secondary">Cargando…</div>
        ) : history.rows.length === 0 ? (
          <ContentUnavailable
            title={filtered ? "Sin coincidencias" : "Sin trabajos en el historial"}
            icon={ListChecks}
            description={filtered ? "Ningún trabajo del historial cumple estos filtros." : "Aquí aparecen los trabajos terminados, fallidos y cancelados."}
          />
        ) : (
          <div className="jobs-list">
            {history.rows.map(row)}
            {history.hasMore && <div ref={sentinel} className="jobs-more secondary">Cargando más…</div>}
          </div>
        )}
      </div>
    </Pane>
  );
}
