import { Users } from "lucide-react";
import { useCallback, useEffect, useState, type KeyboardEvent } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { Connectors, LogView, Recipes, SettingsView, type RunAction, type WatchAuthorization } from "../legacy/LegacyApp";
import { call, desktop } from "../api";
import type { WatchedFolder } from "../types";
import { LibraryView } from "../library/LibraryView";
import { ResolversPane } from "../resolvers/ResolversPane";
import { ContentUnavailable } from "../mac/controls";
import { alertMessage, confirmDestructive, errorText } from "../mac/native";
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
    if (!desktop) return;
    const apply = () =>
      void call<{ accent: string | null }>("system_appearance")
        .then(({ accent }) => accent && document.documentElement.style.setProperty("--accent", accent))
        .catch(() => undefined);
    apply();
    window.addEventListener("focus", apply);
    return () => window.removeEventListener("focus", apply);
  }, []);
}

export function MainWindow() {
  const { data, jobs, problem, refresh } = useAppData();
  const [section, setSection] = useState<MainSection>(() => initialSection(window.location.search));
  const active = useWindowActive();
  useSystemAccent();

  const run: RunAction = useCallback(
    async (label, action, _message, confirmation) => {
      if (confirmation && !(await confirmDestructive(label, confirmation, label))) return;
      try {
        await action();
      } catch (failure) {
        await alertMessage("No se pudo", errorText(failure));
      } finally {
        await refresh();
      }
    },
    [refresh],
  );
  const chooseFolder = useCallback(async () => {
    if (!desktop) return null;
    const chosen = await open({ directory: true });
    return typeof chosen === "string" ? chosen : null;
  }, []);

  const retryWatchScan = () => run("Reintentar escaneo", () => call("watch_scan"));
  const openPrivacySettings = () => run("Abrir Ajustes", () => call("open_privacy_settings"));
  const authorizeWatchedFolder = async (options: WatchAuthorization) => {
    try {
      const folder = await call<WatchedFolder | null>("watch_folder_authorize", options);
      await refresh();
      return folder;
    } catch (failure) {
      await alertMessage("No se pudo autorizar la carpeta", errorText(failure));
      return null;
    }
  };

  const move = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const index = sections.findIndex((item) => item.id === section);
    const next = sections[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), sections.length - 1)];
    setSection(next.id);
  };

  const label = sections.find((item) => item.id === section)?.label ?? "";
  const legacy = (body: React.ReactNode) => (
    <Pane title={label}>
      <div className="legacy">
        <div className="app-shell theme-system legacy-host">
          <main className={`content section-${section}`}>{body}</main>
        </div>
      </div>
    </Pane>
  );

  let detail: React.ReactNode;
  if (!data)
    detail = (
      <Pane title={label}>
        <ContentUnavailable title={problem ? "La biblioteca no está disponible" : "Abriendo la biblioteca…"} icon={Users} description={problem ?? undefined} />
      </Pane>
    );
  else if (section === "library") detail = null;
  else if (section === "people")
    detail = (
      <Pane title="Personas">
        <ContentUnavailable
          title="Personas todavía no está en Tauri"
          icon={Users}
          description={"Llega en la estabilización, igual que en la app Swift:\nhuellas de voz, reconocimiento al transcribir y «Registrar voz»."}
        />
      </Pane>
    );
  else if (section === "connectors") detail = legacy(<Connectors data={data} busy={false} run={run} chooseFolder={chooseFolder} />);
  else if (section === "stt") detail = <ResolversPane key="stt" data={data} role="stt" refresh={refresh} />;
  else if (section === "llms") detail = <ResolversPane key="llm" data={data} role="llm" refresh={refresh} />;
  else if (section === "recipes") detail = legacy(<Recipes data={data} busy={false} run={run} chooseFolder={chooseFolder} />);
  else if (section === "log") detail = legacy(<LogView logs={data.logs} recordings={data.recordings} run={run} />);
  else
    detail = legacy(
      <SettingsView
        data={data}
        busy={false}
        run={run}
        chooseFolder={chooseFolder}
        retryWatchScan={retryWatchScan}
        authorizeWatchedFolder={authorizeWatchedFolder}
        openPrivacySettings={openPrivacySettings}
      />,
    );

  return (
    <div className={`window ${active ? "" : "inactive"}`}>
      <aside className="sidebar" data-tauri-drag-region>
        <div className="sidebar-top" data-tauri-drag-region />
        <nav className="sidebar-list" role="listbox" aria-label="Secciones" tabIndex={0} onKeyDown={move}>
          {sections.map(({ id, label: title, icon: Icon }) => (
            <div
              key={id}
              role="option"
              aria-selected={id === section}
              className={`sidebar-row ${id === section ? "selected" : ""}`}
              onMouseDown={() => setSection(id)}
            >
              <Icon size={16} strokeWidth={1.7} className="sidebar-icon" />
              <span>{title}</span>
            </div>
          ))}
        </nav>
      </aside>
      <section className="detail">
        {data && (
          <div className="section-host" hidden={section !== "library"}>
            <LibraryView data={data} jobs={jobs} refresh={refresh} active={section === "library"} />
          </div>
        )}
        {detail}
      </section>
    </div>
  );
}
