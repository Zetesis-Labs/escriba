import { offersSystemSettings, platformOf } from "../core/platform";
import { PlatformContext } from "./platform";
import { Filter, Users } from "lucide-react";
import { Fragment, useEffect, useState, type KeyboardEvent } from "react";
import { listen } from "@tauri-apps/api/event";
import { ask } from "@tauri-apps/plugin-dialog";
import { call } from "../api";
import { LibraryView } from "../library/LibraryView";
import { useLibraryFilters } from "../library/useLibraryFilters";
import { ResolversPane } from "../resolvers/ResolversPane";
import { RecipesPane } from "../recipes/RecipesPane";
import { LogPane } from "../log/LogPane";
import { SettingsPane } from "../settings/SettingsPane";
import { ConnectorsPane } from "../connectors/ConnectorsPane";
import { PeoplePane } from "../people/PeoplePane";
import { JobsPane } from "../jobs/JobsPane";
import { runningCount } from "../core/jobs";
import { dismissRecorderProblem, openMicrophoneSettings, useRecorderStatus, type RecorderProblem } from "../recording/useRecording";
import { ContentUnavailable } from "../mac/controls";
import { alertMessage } from "../mac/native";
import { Pane } from "./Pane";
import { initialSection, sections, type MainSection } from "./sections";
import { useAppData } from "./useAppData";
import "./window.css";

function useWindowActive() {
  const [active, setActive] = useState(() => document.hasFocus());
  useEffect(() => {
    const focus = () => setActive(true);
    const blur = () => setActive(false);
    window.addEventListener("focus", focus);
    window.addEventListener("blur", blur);
    return () => {
      window.removeEventListener("focus", focus);
      window.removeEventListener("blur", blur);
    };
  }, []);
  return active;
}

function useSystemAccent() {
  useEffect(() => {
    const apply = () =>
      void call<{ accent: string | null }>("system_appearance")
        .then(({ accent }) => accent && document.documentElement.style.setProperty("--accent", accent))
        .catch(() => undefined);
    apply();
    window.addEventListener("focus", apply);
    return () => window.removeEventListener("focus", apply);
  }, []);
}

function useNavigation(go: (section: MainSection) => void) {
  useEffect(() => {
    let alive = true;
    let stop: (() => void) | undefined;
    void listen<string>("escriba://navigate", (event) => {
      if (sections.some((item) => item.id === event.payload)) go(event.payload as MainSection);
    }).then((unlisten) => {
      if (alive) stop = unlisten;
      else unlisten();
    });
    return () => {
      alive = false;
      stop?.();
    };
  }, [go]);
}

function useRecorderAlert(problem: RecorderProblem | null, settingsLink: boolean) {
  useEffect(() => {
    if (!problem) return;
    void (async () => {
      if (problem.denied && settingsLink) {
        const open = await ask(problem.message, { title: "Grabadora", kind: "warning", okLabel: "Abrir Ajustes del Sistema", cancelLabel: "Vale" });
        if (open) await openMicrophoneSettings().catch(() => undefined);
      } else await alertMessage("Grabadora", problem.message);
      await dismissRecorderProblem().catch(() => undefined);
    })();
  }, [problem, settingsLink]);
}

export function MainWindow() {
  const { data, jobs, jobsProblem, problem, refresh } = useAppData();
  const [section, setSection] = useState<MainSection>(() => initialSection(window.location.search));
  const active = useWindowActive();
  const recorder = useRecorderStatus();
  const filters = useLibraryFilters();
  const [reveal, setReveal] = useState<{ id: string; serial: number } | null>(null);
  const running = runningCount(jobs);
  const openNote = (id: string) => {
    filters.clear();
    setSection("library");
    setReveal((previous) => ({ id, serial: (previous?.serial ?? 0) + 1 }));
  };
  useSystemAccent();
  useNavigation(setSection);
  const platform = platformOf(data);
  useRecorderAlert(recorder.problem, offersSystemSettings(platform));

  const move = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const entries = [sections[0], ...filters.saved.map((filter) => ({ id: filter.id, label: filter.name })), ...sections.slice(1)];
    const current = filters.selectedSavedId && section === "library" ? filters.selectedSavedId : section;
    const index = entries.findIndex((item) => item.id === current);
    const next = entries[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), entries.length - 1)];
    const saved = filters.saved.find((filter) => filter.id === next.id);
    if (saved) { setSection("library"); filters.selectSaved(saved); }
    else { setSection(next.id as MainSection); if (next.id === "library") filters.clear(); }
  };

  const label = sections.find((item) => item.id === section)?.label ?? "";
  let detail: React.ReactNode;
  if (!data)
    detail = (
      <Pane title={label}>
        <ContentUnavailable title={problem ? "La biblioteca no está disponible" : "Abriendo la biblioteca…"} icon={Users} description={problem ?? undefined} />
      </Pane>
    );
  else if (section === "library") detail = null;
  else if (section === "people") detail = null;
  else if (section === "jobs") detail = <JobsPane data={data} jobs={jobs} jobsProblem={jobsProblem} onOpen={openNote} />;
  else if (section === "connectors") detail = null;
  else if (section === "stt") detail = <ResolversPane key="stt" data={data} role="stt" refresh={refresh} />;
  else if (section === "llms") detail = <ResolversPane key="llm" data={data} role="llm" refresh={refresh} />;
  else if (section === "recipes") detail = <RecipesPane data={data} refresh={refresh} />;
  else if (section === "log") detail = <LogPane />;
  else detail = <SettingsPane data={data} refresh={refresh} />;

  return (
    <PlatformContext.Provider value={platform}>
    <div className={`window ${active ? "" : "inactive"}`}>
      <aside className="sidebar" data-tauri-drag-region>
        <div className="sidebar-top" data-tauri-drag-region />
        <nav className="sidebar-list" role="listbox" aria-label="Secciones" tabIndex={0} onKeyDown={move}>
          {sections.map(({ id, label: title, icon: Icon }) => (
            <Fragment key={id}>
              <div
                role="option"
                aria-selected={id === section && (id !== "library" || !filters.selectedSavedId)}
                className={`sidebar-row ${id === section && (id !== "library" || !filters.selectedSavedId) ? "selected" : ""}`}
                onMouseDown={() => { setSection(id); if (id === "library") filters.clear(); }}
              >
                <Icon size={16} strokeWidth={1.7} className="sidebar-icon" />
                <span>{title}</span>
                {id === "jobs" && running > 0 && <span className="sidebar-count" aria-label={`${running} en marcha`}>{running}</span>}
              </div>
              {id === "library" && <>
                {filters.saved.map((filter) => (
                  <div
                    key={filter.id}
                    role="option"
                    aria-selected={section === "library" && filters.selectedSavedId === filter.id}
                    className={`sidebar-row sidebar-child ${section === "library" && filters.selectedSavedId === filter.id ? "selected" : ""}`}
                    onMouseDown={() => { setSection("library"); filters.selectSaved(filter); }}
                    title={filter.name}
                  >
                    <Filter size={13} strokeWidth={1.7} className="sidebar-icon" />
                    <span>{filter.name}</span>
                  </div>
                ))}
                {filters.savedError && <div className="sidebar-error" role="alert" title={filters.savedError}>No se pudieron cargar los filtros</div>}
              </>}
            </Fragment>
          ))}
        </nav>
      </aside>
      <section className="detail">
        {data && (
          <div className="section-host" hidden={section !== "library"}>
            <LibraryView data={data} jobs={jobs} refresh={refresh} active={section === "library"} isRecording={recorder.active} filters={filters} reveal={reveal} />
          </div>
        )}
        {data && (
          <div className="section-host" hidden={section !== "connectors"}>
            <ConnectorsPane data={data} refresh={refresh} />
          </div>
        )}
        {data && (
          <div className="section-host" hidden={section !== "people"}>
            <PeoplePane active={section === "people"} />
          </div>
        )}
        {detail}
      </section>
    </div>
    </PlatformContext.Provider>
  );
}
