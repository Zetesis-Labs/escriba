import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  confirm as confirmDialog,
  open,
  save,
} from "@tauri-apps/plugin-dialog";
import {
  AudioLines,
  BookOpen,
  Check,
  ChevronDown,
  CircleAlert,
  Copy,
  Clock3,
  Download,
  ExternalLink,
  FileDown,
  FolderOpen,
  Library,
  ListFilter,
  LoaderCircle,
  Mic,
  Pause,
  Play,
  Plus,
  RefreshCw,
  RotateCcw,
  Save,
  Search,
  Settings2,
  ShieldCheck,
  Sparkles,
  Square,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import type { ReactNode, RefObject } from "react";
import { audioURL, call, desktop, snapshot as getSnapshot } from "./api";
import { recordingSubline } from "./library/rowText";
import {
  cancelProcessing,
  discoverDestination,
  getJobs,
  getRecipeSchema,
  previewDestination,
  processRecording,
  publishRecording,
  rebuildProject,
  subscribeJobs,
  summarizeRecording,
  unpublishRecording,
  validateDestination,
} from "./runtime";
import { SchemaForm } from "./components/SchemaForm";
import type {
  Account,
  Destination,
  Digest,
  JobState,
  JSONObject,
  JSONValue,
  LogEntry,
  Recipe,
  Recording,
  Resolver,
  Segment,
  Settings,
  Snapshot,
  Transcript,
  Version,
  WatchedFolder,
  RuntimeHistory,
  RecipeTrace,
} from "./types";
import "./styles.css";

type Section =
  | "library"
  | "connectors"
  | "stt"
  | "llms"
  | "recipes"
  | "log"
  | "settings";
type AsyncAction = () => Promise<unknown>;
type RunAction = (
  label: string,
  action: AsyncAction,
  message?: string,
  confirmation?: string,
) => Promise<void>;
type WatchAuthorization = {
  folderId?: string;
  name?: string;
  style?: NonNullable<WatchedFolder["style"]>;
};
const DEMO = new URLSearchParams(window.location.search).get("demo") === "1";
const tabs: { id: Section; title: string; icon: typeof Library }[] = [
  { id: "library", title: "Biblioteca", icon: Library },
  { id: "connectors", title: "Conectores", icon: BookOpen },
  { id: "stt", title: "STT", icon: AudioLines },
  { id: "llms", title: "LLMs", icon: Sparkles },
  { id: "recipes", title: "Recetas", icon: BookOpen },
  { id: "log", title: "Registro", icon: ListFilter },
  { id: "settings", title: "Ajustes", icon: Settings2 },
];

const demoSnapshot: Snapshot = {
  recordings: [
    {
      id: "demo-1",
      title: "Reunión del lanzamiento",
      createdAt: "2026-10-09T09:42:00Z",
      source: "reunion-lanzamiento.m4a",
      audioPath: null,
      duration: 187,
      status: "done",
      currentVersionId: "v1",
      recipeId: "default",
      publications: [
        {
          destinationId: "notion-demo",
          name: "Notas de trabajo",
          provider: "notion",
          receipt: {},
          configuration: {},
          updatedAt: "2026-10-09T09:48:00Z",
        },
      ],
      versions: [
        {
          id: "v1",
          createdAt: "2026-10-09T09:47:00Z",
          backend: "WhisperKit",
          recipeId: "default",
          transcript: {
            text: "¿Cómo vamos con el lanzamiento?\nLa migración no llega; propongo moverla una semana.\nVale, y avisamos hoy a soporte.",
            duration: 187,
            segments: [
              {
                start: 0,
                end: 38,
                speaker: "Ana",
                text: "¿Cómo vamos con el lanzamiento?",
              },
              {
                start: 38,
                end: 135,
                speaker: "Luis",
                text: "La migración no llega; propongo moverla una semana.",
              },
              {
                start: 135,
                end: 187,
                speaker: "Ana",
                text: "Vale, y avisamos hoy a soporte.",
              },
            ],
          },
          digest: {
            title: "Reunión del lanzamiento",
            summary:
              "Ana y Luis acuerdan aplazar la migración una semana y avisar hoy a soporte.",
            tags: ["lanzamiento", "migración"],
          },
        },
      ],
    },
    {
      id: "demo-2",
      title: "Ideas para el artículo",
      createdAt: "2026-10-08T16:15:00Z",
      source: "ideas-articulo.m4a",
      audioPath: null,
      duration: 94,
      status: "done",
      currentVersionId: "v2",
      publications: [],
      versions: [
        {
          id: "v2",
          createdAt: "2026-10-08T16:20:00Z",
          backend: "WhisperKit",
          transcript: {
            text: "Abrir con el problema. Después mostrar el ejemplo.",
            segments: [],
          },
        },
      ],
    },
    {
      id: "demo-3",
      title: "Nota del viernes",
      createdAt: "2026-10-07T12:15:00Z",
      source: "nota-viernes.m4a",
      audioPath: null,
      duration: 0,
      status: "pending",
      publications: [],
      versions: [],
    },
  ],
  resolvers: [
    {
      id: "whisper",
      name: "WhisperKit",
      role: "stt",
      local: true,
      enabled: true,
    },
    {
      id: "apple",
      name: "Apple Intelligence",
      role: "llm",
      local: true,
      enabled: true,
    },
  ],
  recipes: [
    {
      id: "default",
      name: "Por defecto",
      kind: "form",
      values: {},
      description: "Transcribe, resume y publica según sus ajustes.",
    },
  ],
  accounts: [
    {
      id: "notion-demo",
      name: "Notion personal",
      provider: "notion",
      enabled: true,
      hasCredential: true,
    },
  ],
  destinations: [
    {
      id: "notion-demo",
      name: "Notas de trabajo",
      provider: "notion",
      account: "notion-demo",
      enabled: true,
      configuration: {},
    },
  ],
  settings: {
    defaultRecipeId: "default",
    projectPath: null,
    watchedFolders: [],
    language: "es",
    whisperModel: "openai_whisper-large-v3_turbo",
    autoProcess: true,
    launchAtLogin: false,
    theme: "system",
  },
  logs: [
    {
      id: "log-1",
      at: "2026-10-09T09:48:00Z",
      level: "info",
      message: "Publicada en Notas de trabajo",
      recordingId: "demo-1",
    },
  ],
  dataPath: "Vista de muestra",
  native: {
    protocolVersion: 1,
    whisper: { available: true },
    llm: { available: true },
  },
};

function errorText(error: unknown) {
  return (error instanceof Error ? error.message : String(error)).replace(/^(BACKEND_UNAVAILABLE|RECIPE_UNAVAILABLE):\s*/, "");
}
function shortDate(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat("es-ES", {
        day: "2-digit",
        month: "short",
        year: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      }).format(date);
}
function clock(seconds: number) {
  const safe = Math.max(0, Math.floor(seconds || 0));
  return `${Math.floor(safe / 3600) ? `${Math.floor(safe / 3600)}:` : ""}${String(Math.floor((safe % 3600) / 60)).padStart(2, "0")}:${String(safe % 60).padStart(2, "0")}`;
}
function headline(section: Section) {
  return tabs.find((tab) => tab.id === section)?.title || "";
}
function uniqueID(prefix: string) {
  return `${prefix}-${crypto.randomUUID()}`;
}
function displayJSON(value: unknown) {
  return JSON.stringify(value, null, 2);
}
function statusLabel(status: Recording["status"]) {
  return {
    pending: "Pendiente",
    processing: "Procesando",
    done: "Lista",
    failed: "Error",
    discarded: "Descartada",
  }[status];
}
function watchedFolderName(
  issue: NonNullable<Snapshot["watchIssues"]>[number],
  settings: Settings,
) {
  const folder = settings.watchedFolders.find(
    (item) => item.id === issue.folderId,
  );
  if (!folder) return issue.path.split("/").at(-1) || issue.path;
  const relativePath = issue.path.startsWith(`${folder.path}/`)
    ? issue.path.slice(folder.path.length + 1)
    : "";
  return relativePath ? `${folder.name} / ${relativePath}` : folder.name;
}
async function republishDestinations(recording: Recording) {
  const failures: string[] = [];
  for (const publication of recording.publications) {
    try {
      await publishRecording(recording.id, publication.destinationId);
    } catch (failure) {
      failures.push(`${publication.name}: ${errorText(failure)}`);
    }
  }
  if (failures.length)
    throw Error(
      `La nota se guardó, pero faltó actualizar ${failures.join("; ")}`,
    );
}
function IconButton({
  title,
  onClick,
  children,
  danger = false,
  disabled = false,
}: {
  title: string;
  onClick: () => void;
  children: ReactNode;
  danger?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      className={`icon-button ${danger ? "danger" : ""}`}
      type="button"
      title={title}
      aria-label={title}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}
function Button({
  children,
  onClick,
  icon: Icon,
  primary = false,
  danger = false,
  disabled = false,
  title,
}: {
  children: ReactNode;
  onClick: () => void;
  icon?: typeof Plus;
  primary?: boolean;
  danger?: boolean;
  disabled?: boolean;
  title?: string;
}) {
  return (
    <button
      type="button"
      className={`button ${primary ? "primary" : ""} ${danger ? "danger" : ""}`}
      onClick={onClick}
      disabled={disabled}
      title={title}
    >
      {Icon && <Icon size={15} strokeWidth={1.8} />}
      {children}
    </button>
  );
}

export default function App() {
  const [data, setData] = useState<Snapshot | null>(DEMO ? demoSnapshot : null);
  const [section, setSection] = useState<Section>("library");
  const [selectedID, setSelectedID] = useState<string | null>(
    DEMO ? "demo-1" : null,
  );
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [jobs, setJobs] = useState<JobState[]>([]);
  const [isRecording, setIsRecording] = useState(false);
  const [isPaused, setIsPaused] = useState(false);
  const [importRecipeID, setImportRecipeID] = useState("");
  const [dropActive, setDropActive] = useState(false);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [detailTab, setDetailTab] = useState<"transcript" | "summary" | "data">(
    "transcript",
  );
  const audio = useRef<HTMLAudioElement>(null);
  const migration = data?.settings.startupMigration;
  const importingLibrary = migration?.state === "importing";
  const watchIssues = data?.watchIssues ?? [];
  const affectedFolderCount = new Set(
    watchIssues.map((issue) => issue.folderId),
  ).size;
  const affectedFolders =
    data?.settings.watchedFolders.filter((folder) =>
      watchIssues.some((issue) => issue.folderId === folder.id),
    ) ?? [];
  const permissionDenied = watchIssues.some((issue) => issue.permissionDenied);

  const refresh = useCallback(async (quiet = false) => {
    if (DEMO) return;
    try {
      const next = await getSnapshot();
      setData(next);
      const capture = await call<{ active: boolean; paused: boolean }>(
        "recording_status",
      );
      setIsRecording(capture.active);
      setIsPaused(capture.paused);
      setSelectedID((current) =>
        current && next.recordings.some((item) => item.id === current)
          ? current
          : null,
      );
    } catch (failure) {
      if (!quiet || desktop) setError(errorText(failure));
    }
  }, []);

  useEffect(() => {
    if (DEMO) return;
    void refresh();
    if (!desktop) return;
    const timer = window.setInterval(
      () => void refresh(true),
      isRecording ? 2000 : 15000,
    );
    let unlisten: (() => void) | undefined;
    void listen("escriba://changed", () => void refresh(true))
      .then((stop) => {
        unlisten = stop;
      })
      .catch((failure) => setError(errorText(failure)));
    const unsubscribe = subscribeJobs(() => setJobs(getJobs()), setError);
    setJobs(getJobs());
    return () => {
      window.clearInterval(timer);
      unlisten?.();
      unsubscribe();
    };
  }, [refresh, isRecording]);

  useEffect(() => {
    if (!desktop || DEMO) return;
    let stop: (() => void) | undefined;
    void import("@tauri-apps/api/webview")
      .then(({ getCurrentWebview }) =>
        getCurrentWebview().onDragDropEvent((event) => {
          if (event.payload.type === "enter" || event.payload.type === "over")
            setDropActive(true);
          if (event.payload.type === "leave") setDropActive(false);
          if (event.payload.type === "drop") {
            setDropActive(false);
            const paths = event.payload.paths.filter((path) =>
              /\.(m4a|mp3|wav|aac|ogg|oga|flac|mp4|mov)$/i.test(path),
            );
            if (paths.length)
              void run("Importar audio", async () => {
                await call("import_audio", {
                  paths,
                  recipeId: importRecipeID || undefined,
                });
                setSection("library");
              });
          }
        }),
      )
      .then((unlisten) => {
        stop = unlisten;
      })
      .catch((failure) => setError(errorText(failure)));
    return () => stop?.();
  }, [importRecipeID]);

  const run: RunAction = async (label, action, message, confirmation) => {
    if (DEMO) {
      setNotice(
        "Vista de muestra. Abre la aplicación Tauri para ejecutar acciones.",
      );
      return;
    }
    if (busy && !jobs.length) return;
    setBusy(label);
    setError(null);
    setNotice(null);
    try {
      if (
        confirmation &&
        !(await confirmDialog(confirmation, { title: label, kind: "warning" }))
      )
        return;
      await action();
      await refresh(true);
      setNotice(message || `${label} completado.`);
    } catch (failure) {
      setError(`${label}: ${errorText(failure)}`);
    } finally {
      setBusy(null);
    }
  };
  const retryWatchScan = () =>
    run(
      "Reintentar escaneo",
      () => call("watch_scan"),
      "Nuevo escaneo solicitado. El aviso desaparecerá cuando se recupere el acceso.",
    );
  const openPrivacySettings = () =>
    run(
      "Abrir Ajustes",
      () => call("open_privacy_settings"),
      "Ajustes del Sistema abiertos. Ve a Privacidad y seguridad → Acceso total al disco y revisa el permiso de Escriba Tauri. Después cierra y abre Escriba Tauri.",
    );
  async function authorizeWatchedFolder(
    options: WatchAuthorization,
  ): Promise<WatchedFolder | null> {
    if (DEMO) {
      setNotice(
        "Vista de muestra. Abre la aplicación Tauri para autorizar carpetas.",
      );
      return null;
    }
    if (busy && !jobs.length) return null;
    setBusy("Autorizar carpeta");
    setError(null);
    setNotice(null);
    try {
      const folder = await call<WatchedFolder | null>(
        "watch_folder_authorize",
        options,
      );
      if (!folder) return null;
      await refresh(true);
      setNotice(
        "Selección de carpeta guardada. El próximo escaneo comprobará si puede leerse.",
      );
      return folder;
    } catch (failure) {
      setError(`Autorizar carpeta: ${errorText(failure)}`);
      return null;
    } finally {
      setBusy(null);
    }
  }
  async function importAudio() {
    if (DEMO) {
      setNotice(
        "Vista de muestra. Abre la aplicación Tauri para importar audio.",
      );
      return;
    }
    try {
      const chosen = await open({
        multiple: true,
        filters: [
          {
            name: "Audio y vídeo",
            extensions: [
              "m4a",
              "mp3",
              "wav",
              "aac",
              "ogg",
              "oga",
              "flac",
              "mp4",
              "mov",
            ],
          },
        ],
      });
      const paths = Array.isArray(chosen) ? chosen : chosen ? [chosen] : [];
      if (paths.length)
        await run("Importar audio", () =>
          call("import_audio", {
            paths,
            recipeId: importRecipeID || undefined,
          }),
        );
    } catch (failure) {
      setError(errorText(failure));
    }
  }
  async function chooseFolder() {
    if (DEMO) {
      setNotice(
        "Vista de muestra. Abre la aplicación Tauri para elegir carpetas.",
      );
      return null;
    }
    try {
      const chosen = await open({ directory: true });
      return typeof chosen === "string" ? chosen : null;
    } catch (failure) {
      setError(`Elegir carpeta: ${errorText(failure)}`);
      return null;
    }
  }
  const visible = useMemo(
    () =>
      (data?.recordings || [])
        .filter((item) => {
          const matches =
            `${item.title} ${item.source} ${item.versions.at(-1)?.transcript.text || ""}`
              .toLocaleLowerCase("es")
              .includes(query.toLocaleLowerCase("es"));
          return (
            matches &&
            (filter === "all"
              ? item.status !== "discarded"
              : item.status === filter)
          );
        })
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    [data?.recordings, query, filter],
  );
  const selected =
    visible.find((item) => item.id === selectedID) || visible[0] || null;
  const activeVersion =
    selected?.versions.find(
      (version) => version.id === selected.currentVersionId,
    ) || selected?.versions.at(-1);

  return (
    <div className={`app-shell theme-${data?.settings.theme || "system"}`}>
      <aside className="sidebar">
        <div className="brand" data-tauri-drag-region>
          <strong data-tauri-drag-region>Escriba</strong>
        </div>
        <nav aria-label="Secciones">
          {tabs.map(({ id, title, icon: Icon }) => (
            <button
              type="button"
              key={id}
              className={`nav-item ${section === id ? "active" : ""}`}
              onClick={() => setSection(id)}
              aria-current={section === id ? "page" : undefined}
            >
              <Icon size={17} strokeWidth={1.7} />
              <span>{title}</span>
              {id === "library" && (
                <small>
                  {importingLibrary
                    ? "…"
                    : data?.recordings.filter(
                        (item) => item.status !== "discarded",
                      ).length || 0}
                </small>
              )}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="small-rule" />
          <div className="sidebar-state">
            <span
              className={`state-dot ${affectedFolderCount ? "issue" : jobs.length || importingLibrary ? "working" : data?.settings.autoProcess === false ? "paused" : ""}`}
            />
            <span>
              {affectedFolderCount
                ? `${affectedFolderCount} carpeta${affectedFolderCount > 1 ? "s" : ""} con errores`
                : importingLibrary
                ? "Incorporando biblioteca…"
                : jobs.length
                  ? `${jobs.length} trabajo${jobs.length > 1 ? "s" : ""} en curso`
                  : data?.settings.autoProcess === false
                    ? "Procesamiento pausado"
                    : "Sin trabajos en curso"}
            </span>
          </div>
          {DEMO && <small className="sidebar-path">Vista de muestra</small>}
        </div>
      </aside>
      <div className="main-frame">
        <header className="topbar" data-tauri-drag-region>
          <strong className="toolbar-title" data-tauri-drag-region>
            {headline(section)}
          </strong>
          <div className="topbar-actions">
            {DEMO && <span className="demo-tag">MUESTRA</span>}
            {busy && (
              <span className="busy-label">
                <LoaderCircle size={14} className="spin" /> {busy}
              </span>
            )}
            <IconButton title="Actualizar" onClick={() => void refresh()}>
              <RefreshCw size={17} />
            </IconButton>
          </div>
        </header>
        {error && (
          <div className="banner error" role="alert">
            <CircleAlert size={18} />
            <span>{error}</span>
            <IconButton title="Cerrar aviso" onClick={() => setError(null)}>
              <X size={16} />
            </IconButton>
          </div>
        )}
        {notice && (
          <div className="banner success" role="status">
            <Check size={17} />
            <span>{notice}</span>
            <IconButton title="Cerrar aviso" onClick={() => setNotice(null)}>
              <X size={16} />
            </IconButton>
          </div>
        )}
        {watchIssues.length > 0 && data && (
          <div className="banner watch-warning" role="alert">
            <CircleAlert size={18} />
            <div className="watch-copy">
              <strong>Hay carpetas vigiladas que no se pueden revisar.</strong>
              {watchIssues.map((issue, index) => (
                <p key={`${issue.folderId}:${issue.path}:${index}`}>
                  <strong>{watchedFolderName(issue, data.settings)}:</strong>{" "}
                  {issue.permissionDenied
                    ? "macOS ha denegado el acceso. Vuelve a seleccionar esta carpeta para autorizarla. Acceso total al disco es una alternativa si sigue fallando."
                    : issue.message.split(/\r?\n/, 1)[0] ||
                      "Comprueba que la carpeta siga disponible."}
                </p>
              ))}
            </div>
            <div className="watch-actions">
              {affectedFolders.map((folder) => (
                <Button
                  key={folder.id}
                  primary
                  disabled={Boolean(busy)}
                  onClick={() =>
                    void authorizeWatchedFolder({ folderId: folder.id })
                  }
                >
                  {affectedFolders.length === 1
                    ? folder.authorizationSaved
                      ? "Volver a autorizar"
                      : "Autorizar carpeta"
                    : `Autorizar «${folder.name}»`}
                </Button>
              ))}
              {permissionDenied && (
                <Button
                  disabled={Boolean(busy)}
                  onClick={() => void openPrivacySettings()}
                >
                  Acceso total al disco…
                </Button>
              )}
              <Button
                icon={RefreshCw}
                disabled={Boolean(busy)}
                onClick={() => void retryWatchScan()}
              >
                Reintentar
              </Button>
            </div>
          </div>
        )}
        {migration?.state === "error" && (
          <div className="banner error" role="alert">
            <CircleAlert size={18} />
            <span>
              No se pudo incorporar la biblioteca anterior: {migration.message}.
              Puedes reintentarlo desde Ajustes o al volver a abrir la app.
            </span>
            <Button onClick={() => setSection("settings")}>Abrir ajustes</Button>
          </div>
        )}
        {data?.settings.watchMigration?.state === "error" && (
          <div className="banner error" role="alert">
            <CircleAlert size={18} />
            <span>
              No se pudieron recuperar las carpetas vigiladas:{" "}
              {data.settings.watchMigration.message}. Puedes añadirlas en Ajustes
              o volver a abrir la app para reintentar.
            </span>
            <Button onClick={() => setSection("settings")}>Abrir ajustes</Button>
          </div>
        )}
        {migration?.state === "imported" && !migration.dismissed && (
          <div className="banner success migration-notice" role="status">
            <Check size={17} />
            <span>
              Se han incorporado {migration.report.recordings} grabaciones de
              Escriba.
              {migration.report.audioMissing > 0 &&
                ` ${migration.report.audioMissing} grabaciones no tienen una copia de audio disponible.`}
            </span>
            <IconButton
              title="Cerrar aviso de importación"
              onClick={() =>
                void run("Cerrar aviso", () =>
                  call("settings_save", {
                    settings: {
                      startupMigration: { ...migration, dismissed: true },
                    },
                  }),
                )
              }
            >
              <X size={16} />
            </IconButton>
          </div>
        )}
        {!importingLibrary && data?.settings.autoProcess === false && (
          <div className="banner migration-notice" role="status">
            <Pause size={17} />
            <span>
              <strong>Procesamiento automático pausado.</strong>{" "}
              Revisa las recetas, sus resolutores y destinos antes de reanudar:
              el procesamiento puede publicar en los destinos configurados.
            </span>
            <Button onClick={() => setSection("recipes")}>Revisar recetas</Button>
            <Button
              icon={Play}
              primary
              disabled={Boolean(busy)}
              onClick={() =>
                void run("Reanudar procesamiento", () =>
                  call("settings_save", { settings: { autoProcess: true } }),
                )
              }
            >
              Reanudar procesamiento
            </Button>
          </div>
        )}
        {!data || importingLibrary ? (
          <div className="center-state">
            <LoaderCircle className="spin" />
            <h2>
              {importingLibrary
                ? "Incorporando tus grabaciones"
                : "Abriendo la biblioteca"}
            </h2>
            <p>
              {importingLibrary
                ? "Copiando el audio y las versiones de Escriba. La biblioteca original se conserva."
                : "Preparando tus notas de voz."}
            </p>
          </div>
        ) : (
          <main className={`content section-${section}`}>
            {section === "library" && (
              <>
                <div className="page-heading">
                  <div>
                    <h1>Grabaciones</h1>
                  </div>
                  <div className="heading-actions">
                    <select
                      aria-label="Receta para audio nuevo"
                      value={importRecipeID}
                      onChange={(event) =>
                        setImportRecipeID(event.target.value)
                      }
                    >
                      <option value="">Receta por defecto</option>
                      {data.recipes.map((recipe) => (
                        <option value={recipe.id} key={recipe.id}>
                          {recipe.name}
                        </option>
                      ))}
                    </select>
                    <Button icon={Upload} onClick={() => void importAudio()}>
                      Importar
                    </Button>
                    <Button
                      icon={isRecording ? Square : Mic}
                      primary
                      onClick={() =>
                        void run(
                          isRecording
                            ? "Detener grabación"
                            : "Iniciar grabación",
                          async () => {
                            if (isRecording) {
                              await call("recording_stop", {
                                recipeId: importRecipeID || undefined,
                              });
                              setIsRecording(false);
                              setIsPaused(false);
                            } else {
                              await call("recording_start", {});
                              setIsRecording(true);
                            }
                          },
                        )
                      }
                    >
                      {isRecording ? "Detener" : "Grabar"}
                    </Button>
                  </div>
                </div>
                {isRecording && (
                  <div className="recording-strip">
                    <span
                      className={`record-pulse ${isPaused ? "paused" : ""}`}
                    />
                    <strong>
                      {isPaused ? "Grabación en pausa" : "Grabando audio"}
                    </strong>
                    <Button
                      icon={isPaused ? Play : Pause}
                      onClick={() =>
                        void run(
                          isPaused ? "Reanudar grabación" : "Pausar grabación",
                          async () => {
                            await call(
                              isPaused ? "recording_resume" : "recording_pause",
                            );
                            setIsPaused(!isPaused);
                          },
                        )
                      }
                    >
                      {isPaused ? "Reanudar" : "Pausar"}
                    </Button>
                  </div>
                )}
                <div className="library-layout">
                  <div className="recording-list panel">
                    <div className="list-tools">
                      <div className="searchbox">
                        <Search size={16} />
                        <input
                          aria-label="Buscar grabaciones"
                          placeholder="Buscar grabaciones"
                          value={query}
                          onChange={(event) => setQuery(event.target.value)}
                        />
                      </div>
                      <select
                        aria-label="Filtrar por estado"
                        value={filter}
                        onChange={(event) => setFilter(event.target.value)}
                      >
                        <option value="all">Todas</option>
                        <option value="pending">Pendientes</option>
                        <option value="processing">Procesando</option>
                        <option value="done">Listas</option>
                        <option value="failed">Errores</option>
                        <option value="discarded">Descartadas</option>
                      </select>
                    </div>
                    <div className="list-count">
                      {visible.length} grabaciones
                    </div>
                    <div className="recording-items">
                      {visible.map((item) => (
                        <button
                          type="button"
                          key={item.id}
                          className={`recording-item ${item.id === selected?.id ? "selected" : ""}`}
                          onClick={() => {
                            setSelectedID(item.id);
                            setDetailTab("transcript");
                          }}
                        >
                          <span className={`record-icon ${item.status}`}>
                            <AudioLines size={18} />
                          </span>
                          <span className="record-copy">
                            <strong>{item.title}</strong>
                            <small>
                              {shortDate(item.createdAt)} <i>·</i>{" "}
                              {clock(item.duration)}
                            </small>
                            <span className="record-subline">
                              {recordingSubline(
                                item,
                                jobs.find((job) => job.recordingId === item.id),
                              )}
                            </span>
                          </span>
                          <span
                            className={`status-dot ${item.status}`}
                            title={statusLabel(item.status)}
                          />
                        </button>
                      ))}
                      {!visible.length && (
                        <div className="empty-list">
                          <AudioLines size={22} />
                          <strong>Sin grabaciones</strong>
                          <span>
                            {query || filter !== "all"
                              ? "Prueba con otra búsqueda o filtro."
                              : "Importa audio o inicia una grabación."}
                          </span>
                        </div>
                      )}
                    </div>
                  </div>
                  <div className="record-detail panel">
                    {selected ? (
                      <RecordingDetail
                        key={`${selected.id}:${activeVersion?.id || ""}:${activeVersion?.digest?.summary || ""}`}
                        recording={selected}
                        version={activeVersion}
                        recipes={data.recipes}
                        destinations={data.destinations}
                        jobs={jobs}
                        tab={detailTab}
                        setTab={setDetailTab}
                        busy={Boolean(busy) && jobs.length === 0}
                        audio={audio}
                        run={run}
                        setError={setError}
                      />
                    ) : (
                      <div className="empty-detail">
                        <AudioLines size={26} />
                        <h2>Elige una grabación</h2>
                        <p>
                          Aquí verás su transcripción, resumen y publicaciones.
                        </p>
                      </div>
                    )}
                  </div>
                </div>
              </>
            )}
            {section === "connectors" && (
              <Connectors
                data={data}
                busy={Boolean(busy) && jobs.length === 0}
                run={run}
                chooseFolder={chooseFolder}
              />
            )}
            {(section === "stt" || section === "llms") && (
              <Resolvers
                data={data}
                role={section === "stt" ? "stt" : "llm"}
                busy={Boolean(busy) && jobs.length === 0}
                run={run}
              />
            )}
            {section === "recipes" && (
              <Recipes
                data={data}
                busy={Boolean(busy) && jobs.length === 0}
                run={run}
                chooseFolder={chooseFolder}
              />
            )}
            {section === "log" && (
              <LogView
                logs={data.logs}
                recordings={data.recordings}
                run={run}
              />
            )}
            {section === "settings" && (
              <SettingsView
                data={data}
                busy={Boolean(busy) && jobs.length === 0}
                run={run}
                chooseFolder={chooseFolder}
                retryWatchScan={retryWatchScan}
                authorizeWatchedFolder={authorizeWatchedFolder}
                openPrivacySettings={openPrivacySettings}
              />
            )}
          </main>
        )}
      </div>
      {dropActive && (
        <div className="drop-overlay">
          <Upload size={30} />
          <strong>Suelta el audio para importarlo</strong>
          <span>Se copiará a tu biblioteca local.</span>
        </div>
      )}
    </div>
  );
}

function RecordingDetail({
  recording,
  version,
  recipes,
  destinations,
  jobs,
  tab,
  setTab,
  busy,
  audio,
  run,
  setError,
}: {
  recording: Recording;
  version?: Version;
  recipes: Recipe[];
  destinations: Destination[];
  jobs: JobState[];
  tab: "transcript" | "summary" | "data";
  setTab: (tab: "transcript" | "summary" | "data") => void;
  busy: boolean;
  audio: RefObject<HTMLAudioElement | null>;
  run: RunAction;
  setError: (message: string) => void;
}) {
  const [title, setTitle] = useState(recording.title);
  const [text, setText] = useState(version?.transcript.text || "");
  const [segments, setSegments] = useState<Segment[]>(
    version?.transcript.segments || [],
  );
  const [speakerFrom, setSpeakerFrom] = useState("");
  const [speakerTo, setSpeakerTo] = useState("");
  const [speed, setSpeed] = useState(1);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [digest, setDigest] = useState<Digest>(
    version?.digest || { title: "", summary: "", tags: [] },
  );
  const [dataText, setDataText] = useState(displayJSON(version?.data ?? {}));
  const [exportFormat, setExportFormat] = useState<
    "txt" | "md" | "srt" | "json"
  >("txt");
  const [recipeID, setRecipeID] = useState(recording.recipeId || "");
  const currentJob = jobs.find((job) => job.recordingId === recording.id);
  const speakers = [
    ...new Set(
      segments
        .map((segment) => segment.speaker)
        .filter((value): value is string => Boolean(value)),
    ),
  ];
  const duration = recording.duration || version?.transcript.duration || 0;

  async function saveTranscript() {
    const corrected: Transcript = {
      ...(version?.transcript || { text: "", segments: [] }),
      text: segments.length
        ? segments.map((segment) => segment.text).join("\n")
        : text,
      segments,
    };
    await run("Guardar corrección", async () => {
      await call("version_save", {
        recordingId: recording.id,
        transcript: corrected,
        digest: version?.digest ?? null,
        data: version?.data ?? null,
        backend: "Corrección manual",
        recipeId: version?.recipeId,
        inputs: version?.inputs,
      });
      await republishDestinations(recording);
    });
  }
  async function exportTranscript() {
    if (!version) return;
    if (DEMO) {
      await run("Exportar", async () => {});
      return;
    }
    try {
      const path = await save({
        defaultPath: `${recording.title.replace(/[\\/:*?"<>|]/g, "-")}.${exportFormat}`,
        filters: [
          { name: exportFormat.toUpperCase(), extensions: [exportFormat] },
        ],
      });
      if (!path) return;
      const transcript = version.transcript;
      const body = transcript.segments.length
        ? transcript.segments
            .map(
              (segment) =>
                `${segment.speaker ? `${segment.speaker}: ` : ""}${segment.text}`,
            )
            .join("\n\n")
        : transcript.text;
      const links = recording.publications.flatMap((publication) =>
        typeof publication.receipt.url === "string"
          ? [`${publication.name}: ${publication.receipt.url}`]
          : [],
      );
      const contents =
        exportFormat === "json"
          ? displayJSON({
              recording: {
                id: recording.id,
                title: recording.title,
                createdAt: recording.createdAt,
                source: recording.source,
                duration: recording.duration,
                status: recording.status,
              },
              version,
              publications: recording.publications,
            }) + "\n"
          : exportFormat === "srt"
            ? (transcript.segments.length
                ? transcript.segments
                : [{ start: 0, end: duration, text: transcript.text }]
              )
                .map(
                  (segment, index) =>
                    `${index + 1}\n${srtTime(segment.start)} --> ${srtTime(segment.end)}\n${segment.speaker ? `${segment.speaker}: ` : ""}${segment.text}\n`,
                )
                .join("\n")
            : exportFormat === "md"
              ? `# ${recording.title}\n\n*Grabada: ${shortDate(recording.createdAt)} · Duración: ${clock(duration)}*\n\n${version.digest ? `## Resumen\n\n${version.digest.summary}\n\n${version.digest.tags.length ? `Etiquetas: ${version.digest.tags.join(", ")}\n\n` : ""}` : ""}## Transcripción\n\n${transcript.segments.length ? transcript.segments.map((segment) => `${segment.speaker ? `**${segment.speaker}:** ` : ""}${segment.text}`).join("\n\n") : transcript.text}\n${version.data != null ? `\n## Datos\n\n\`\`\`json\n${displayJSON(version.data)}\n\`\`\`\n` : ""}${links.length ? `\n## Publicaciones\n\n${links.map((link) => `- ${link}`).join("\n")}\n` : ""}`
              : `${recording.title}\nGrabada: ${shortDate(recording.createdAt)} · Duración: ${clock(duration)}\n${version.digest ? `\nRESUMEN\n${version.digest.summary}\n${version.digest.tags.length ? `Etiquetas: ${version.digest.tags.join(", ")}\n` : ""}` : ""}\nTRANSCRIPCIÓN\n${body}\n${version.data != null ? `\nDATOS\n${displayJSON(version.data)}\n` : ""}${links.length ? `\nPUBLICACIONES\n${links.join("\n")}\n` : ""}`;
      await run(`Exportar ${exportFormat.toUpperCase()}`, () =>
        call("export_file", { path, contents }),
      );
    } catch (failure) {
      setError(errorText(failure));
    }
  }

  return (
    <>
      <div className="detail-header">
        <div>
          <p className="eyebrow">
            {statusLabel(recording.status)}{" "}
            {currentJob && `· ${currentJob.stage}`}
          </p>
          <input
            className="title-input"
            aria-label="Título de la grabación"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            onBlur={() => {
              if (title.trim() && title !== recording.title)
                void run("Cambiar título", async () => {
                  await call("recording_update", {
                    id: recording.id,
                    title: title.trim(),
                  });
                  await republishDestinations(recording);
                });
            }}
          />
          <div className="detail-meta">
            <span>
              <Clock3 size={13} /> {shortDate(recording.createdAt)}
            </span>
            <span>{clock(duration)}</span>
            <span>{recording.source.split("/").at(-1)}</span>
          </div>
        </div>
        <span className={`status-pill ${recording.status}`}>
          {statusLabel(recording.status)}
        </span>
      </div>
      <div className="audio-bar">
        {recording.audioPath ? (
          <>
            <IconButton
              title={playing ? "Pausar audio" : "Reproducir audio"}
              onClick={() => {
                if (!audio.current) return;
                if (audio.current.paused) void audio.current.play();
                else audio.current.pause();
              }}
            >
              <span className="play-icon">
                {playing ? <Pause size={18} /> : <Play size={18} />}
              </span>
            </IconButton>
            <span className="time-readout">{clock(position)}</span>
            <input
              aria-label="Posición del audio"
              className="seek"
              type="range"
              min={0}
              max={Math.max(1, duration)}
              step={0.1}
              value={Math.min(position, duration)}
              onChange={(event) => {
                if (audio.current)
                  audio.current.currentTime = Number(event.target.value);
                setPosition(Number(event.target.value));
              }}
            />
            <span className="time-readout">{clock(duration)}</span>
            <select
              aria-label="Velocidad de reproducción"
              value={speed}
              onChange={(event) => {
                const next = Number(event.target.value);
                setSpeed(next);
                if (audio.current) audio.current.playbackRate = next;
              }}
            >
              {[0.75, 1, 1.25, 1.5, 2].map((value) => (
                <option key={value} value={value}>
                  {value}×
                </option>
              ))}
            </select>
            <audio
              ref={audio}
              src={audioURL(recording.audioPath)}
              onTimeUpdate={(event) =>
                setPosition(event.currentTarget.currentTime)
              }
              onPlay={() => setPlaying(true)}
              onPause={() => setPlaying(false)}
              onEnded={() => setPlaying(false)}
            />
          </>
        ) : (
          <span className="muted">La copia de audio no está disponible.</span>
        )}
      </div>
      <div className="detail-actions">
        <Button
          icon={
            currentJob || recording.status === "processing" ? Square : RotateCcw
          }
          onClick={() => {
            if (currentJob || recording.status === "processing")
              void run("Cancelar proceso", () =>
                cancelProcessing(recording.id),
              );
            else
              void run("Reprocesar", () =>
                processRecording(recording.id, {
                  recipeId: recipeID || undefined,
                  force: true,
                }),
              );
          }}
        >
          {currentJob || recording.status === "processing"
            ? "Cancelar"
            : "Reprocesar"}
        </Button>
        <Button
          icon={Sparkles}
          onClick={() =>
            void run("Detectar hablantes", () =>
              processRecording(recording.id, { diarize: true, force: true }),
            )
          }
          disabled={busy || !recording.audioPath}
        >
          Diarizar
        </Button>
        <Button
          icon={Play}
          onClick={() =>
            void run("Probar receta", () =>
              processRecording(recording.id, {
                recipeId: recipeID || undefined,
                dryRun: true,
              }),
            )
          }
          disabled={busy}
        >
          Probar receta
        </Button>
      </div>
      {recording.error && (
        <div className="inline-error">
          <CircleAlert size={15} />
          {recording.error}
        </div>
      )}
      <div className="detail-selectors">
        <label>
          Receta para el próximo proceso
          <select
            value={recipeID}
            onChange={(event) => {
              const id = event.target.value;
              setRecipeID(id);
              void run("Asignar receta", () =>
                call("recording_update", {
                  id: recording.id,
                  recipeId: id || null,
                }),
              );
            }}
          >
            <option value="">Por defecto</option>
            {recipes.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Versión
          <select
            value={version?.id || ""}
            onChange={(event) =>
              void run("Elegir versión", async () => {
                await call("version_select", {
                  recordingId: recording.id,
                  versionId: event.target.value,
                });
                await republishDestinations(recording);
              })
            }
          >
            {recording.versions.map((item, index) => (
              <option key={item.id} value={item.id}>
                v{index + 1} · {shortDate(item.createdAt)} · {item.backend}
              </option>
            ))}
          </select>
        </label>
      </div>
      <div className="subtabs" role="tablist" aria-label="Contenido de la nota">
        {(
          [
            ["transcript", "Transcripción"],
            ["summary", "Resumen"],
            ["data", "Datos"],
          ] as const
        ).map(([id, label]) => (
          <button
            type="button"
            role="tab"
            aria-selected={tab === id}
            className={tab === id ? "active" : ""}
            key={id}
            onClick={() => setTab(id)}
          >
            {label}
          </button>
        ))}
      </div>
      {!version ? (
        <div className="empty-content">
          Esta grabación aún no tiene una versión. Elige{" "}
          <strong>Reprocesar</strong> para crearla.
        </div>
      ) : tab === "transcript" ? (
        <div className="detail-body">
          <div className="section-line">
            <strong>Texto de la grabación</strong>
            <span className="muted">Editar crea una versión nueva.</span>
          </div>
          {segments.length ? (
            <div className="segment-list">
              {segments.map((segment, index) => (
                <div className="segment-row" key={`${index}-${segment.start}`}>
                  <button
                    type="button"
                    className="segment-time"
                    onClick={() => {
                      if (audio.current) {
                        audio.current.currentTime = segment.start;
                        void audio.current.play();
                      }
                    }}
                  >
                    {clock(segment.start)}
                  </button>
                  <div>
                    <input
                      aria-label={`Hablante del segmento ${index + 1}`}
                      className="speaker-input"
                      value={segment.speaker || ""}
                      onChange={(event) =>
                        setSegments((current) =>
                          current.map((item, i) =>
                            i === index
                              ? { ...item, speaker: event.target.value || null }
                              : item,
                          ),
                        )
                      }
                      placeholder="Sin hablante"
                    />
                    <textarea
                      aria-label={`Texto del segmento ${index + 1}`}
                      rows={Math.max(2, Math.ceil(segment.text.length / 90))}
                      value={segment.text}
                      onChange={(event) =>
                        setSegments((current) =>
                          current.map((item, i) =>
                            i === index
                              ? { ...item, text: event.target.value }
                              : item,
                          ),
                        )
                      }
                    />
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <textarea
              className="full-transcript"
              aria-label="Transcripción"
              value={text}
              onChange={(event) => setText(event.target.value)}
              rows={12}
            />
          )}
          {speakers.length > 0 && (
            <div className="speaker-tools">
              <select
                aria-label="Hablante de origen"
                value={speakerFrom}
                onChange={(event) => setSpeakerFrom(event.target.value)}
              >
                <option value="">Hablante…</option>
                {speakers.map((speaker) => (
                  <option key={speaker}>{speaker}</option>
                ))}
              </select>
              <input
                aria-label="Nuevo nombre o hablante de destino"
                placeholder="Nuevo nombre o unir con…"
                value={speakerTo}
                onChange={(event) => setSpeakerTo(event.target.value)}
              />
              <Button
                onClick={() => {
                  if (speakerFrom && speakerTo.trim())
                    setSegments((current) =>
                      current.map((segment) =>
                        segment.speaker === speakerFrom
                          ? { ...segment, speaker: speakerTo.trim() }
                          : segment,
                      ),
                    );
                }}
              >
                Aplicar
              </Button>
            </div>
          )}
          <div className="footer-actions">
            <Button
              icon={Save}
              primary
              onClick={() => void saveTranscript()}
              disabled={busy}
            >
              Guardar corrección
            </Button>
            <div className="export-actions">
              <select
                aria-label="Formato de exportación"
                value={exportFormat}
                onChange={(event) =>
                  setExportFormat(event.target.value as typeof exportFormat)
                }
              >
                <option value="txt">TXT</option>
                <option value="md">Markdown</option>
                <option value="srt">SRT</option>
                <option value="json">JSON</option>
              </select>
              <Button icon={FileDown} onClick={() => void exportTranscript()}>
                Exportar
              </Button>
            </div>
          </div>
        </div>
      ) : tab === "summary" ? (
        <div className="detail-body">
          <div className="section-line">
            <strong>Resumen de esta versión</strong>
            <Button
              icon={Sparkles}
              onClick={() =>
                void run("Resumir", () => summarizeRecording(recording.id))
              }
              disabled={busy}
            >
              Generar
            </Button>
          </div>
          <div className="field">
            <label htmlFor="digest-title">Título</label>
            <input
              id="digest-title"
              value={digest.title}
              onChange={(event) =>
                setDigest({ ...digest, title: event.target.value })
              }
            />
          </div>
          <div className="field">
            <label htmlFor="digest-summary">Resumen</label>
            <textarea
              id="digest-summary"
              rows={8}
              value={digest.summary}
              onChange={(event) =>
                setDigest({ ...digest, summary: event.target.value })
              }
            />
          </div>
          <div className="field">
            <label htmlFor="digest-tags">Etiquetas</label>
            <input
              id="digest-tags"
              value={digest.tags.join(", ")}
              onChange={(event) =>
                setDigest({
                  ...digest,
                  tags: event.target.value
                    .split(",")
                    .map((tag) => tag.trim())
                    .filter(Boolean),
                })
              }
            />
          </div>
          <div className="footer-actions">
            <Button
              icon={Save}
              primary
              onClick={() =>
                void run("Guardar resumen", async () => {
                  await call("version_update", {
                    recordingId: recording.id,
                    versionId: version.id,
                    digest,
                  });
                  await republishDestinations(recording);
                })
              }
            >
              Guardar
            </Button>
            <Button
              icon={Trash2}
              danger
              onClick={() =>
                void run(
                  "Quitar resumen",
                  async () => {
                    await call("version_update", {
                      recordingId: recording.id,
                      versionId: version.id,
                      digest: null,
                    });
                    await republishDestinations(recording);
                  },
                  undefined,
                  "¿Quitar el resumen de esta versión?",
                )
              }
            >
              Quitar resumen
            </Button>
          </div>
        </div>
      ) : (
        <div className="detail-body">
          <div className="section-line">
            <strong>Datos de la receta</strong>
            <span className="muted">JSON de esta versión.</span>
          </div>
          <textarea
            className="code-area"
            aria-label="Datos JSON"
            rows={14}
            value={dataText}
            onChange={(event) => setDataText(event.target.value)}
          />
          <div className="footer-actions">
            <Button
              icon={Save}
              primary
              onClick={() => {
                try {
                  const parsed = JSON.parse(dataText) as JSONValue;
                  void run("Guardar datos", async () => {
                    await call("version_update", {
                      recordingId: recording.id,
                      versionId: version.id,
                      data: parsed,
                    });
                    await republishDestinations(recording);
                  });
                } catch (failure) {
                  setError(`JSON inválido: ${errorText(failure)}`);
                }
              }}
            >
              Guardar datos
            </Button>
          </div>
        </div>
      )}
      <div className="detail-bottom">
        <div className="section-line">
          <strong>Publicaciones</strong>
          <span className="muted">{recording.publications.length} activas</span>
        </div>
        {recording.publications.map((publication) => (
          <div className="publication-row" key={publication.destinationId}>
            <span>
              <ShieldCheck size={16} />
              {publication.name}
              <small>
                {publication.provider} · {shortDate(publication.updatedAt)}
              </small>
            </span>
            <div className="heading-actions">
              {typeof publication.receipt.url === "string" && (
                <Button
                  icon={ExternalLink}
                  onClick={() =>
                    void run("Abrir publicación", () =>
                      call("open_url", { url: publication.receipt.url }),
                    )
                  }
                >
                  Abrir
                </Button>
              )}
              <Button
                icon={Trash2}
                danger
                onClick={() =>
                  void run(
                    "Retirar publicación",
                    () =>
                      unpublishRecording(
                        recording.id,
                        publication.destinationId,
                      ),
                    undefined,
                    `¿Retirar la publicación en ${publication.name}?`,
                  )
                }
              >
                Retirar
              </Button>
            </div>
          </div>
        ))}
        <div className="publish-row">
          <select
            aria-label="Destino para publicar"
            id={`destination-${recording.id}`}
            defaultValue=""
          >
            <option value="">Elegir destino…</option>
            {destinations
              .filter((item) => item.enabled)
              .map((item) => (
                <option key={item.id} value={item.id}>
                  {item.name}
                </option>
              ))}
          </select>
          <Button
            icon={Upload}
            onClick={() => {
              const id = (
                document.getElementById(
                  `destination-${recording.id}`,
                ) as HTMLSelectElement | null
              )?.value;
              if (id)
                void run("Publicar", () => publishRecording(recording.id, id));
              else setError("Elige un destino antes de publicar.");
            }}
          >
            Publicar
          </Button>
        </div>
      </div>
      <div className="footer-actions">
        <Button
          icon={Copy}
          disabled={!version}
          onClick={() =>
            void run("Copiar texto", () =>
              navigator.clipboard.writeText(version?.transcript.text || ""),
            )
          }
        >
          Copiar texto
        </Button>
        <Button
          icon={Copy}
          disabled={!version}
          onClick={() =>
            void run("Copiar JSON", () =>
              navigator.clipboard.writeText(JSON.stringify(version, null, 2)),
            )
          }
        >
          Copiar JSON
        </Button>
      </div>
      <div className="danger-zone">
        <Button
          icon={Trash2}
          danger
          disabled={!!currentJob}
          onClick={() =>
            void run(
              "Borrar definitivamente",
              () => call("recording_delete", { id: recording.id }),
              undefined,
              `¿Borrar definitivamente «${recording.title}», todas sus versiones y su copia de audio? Las publicaciones externas permanecerán en sus destinos.`,
            )
          }
        >
          Borrar definitivamente
        </Button>
        <Button
          icon={Trash2}
          danger
          onClick={() =>
            void run(
              "Quitar audio",
              () => call("recording_remove_audio", { id: recording.id }),
              undefined,
              "¿Quitar la copia de audio de la biblioteca? La transcripción se conservará.",
            )
          }
          disabled={!recording.audioPath}
        >
          Quitar audio
        </Button>
        {recording.status === "discarded" ? (
          <Button
            icon={RotateCcw}
            onClick={() =>
              void run("Restaurar grabación", () =>
                call("recording_restore", { id: recording.id }),
              )
            }
          >
            Restaurar
          </Button>
        ) : (
          <Button
            icon={Trash2}
            danger
            onClick={() =>
              void run(
                "Descartar grabación",
                () => call("recording_discard", { id: recording.id }),
                undefined,
                "¿Descartar esta grabación?",
              )
            }
          >
            Descartar
          </Button>
        )}
      </div>
    </>
  );
}
function srtTime(value: number) {
  const ms = Math.round(value * 1000);
  return `${String(Math.floor(ms / 3600000)).padStart(2, "0")}:${String(Math.floor((ms % 3600000) / 60000)).padStart(2, "0")}:${String(Math.floor((ms % 60000) / 1000)).padStart(2, "0")},${String(ms % 1000).padStart(3, "0")}`;
}

function Connectors({
  data,
  busy,
  run,
  chooseFolder,
}: {
  data: Snapshot;
  busy: boolean;
  run: RunAction;
  chooseFolder: () => Promise<string | null>;
}) {
  const [selectedAccountID, setSelectedAccountID] = useState<string | null>(
    null,
  );
  const [selectedDestinationID, setSelectedDestinationID] = useState<
    string | null
  >(null);
  const [draft, setDraft] = useState<Account | null>(null);
  const [credential, setCredential] = useState("");
  const [result, setResult] = useState<unknown>(null);
  const [resultTitle, setResultTitle] = useState("");
  const [previewRecordingID, setPreviewRecordingID] = useState("");
  const account = data.accounts.find((item) => item.id === selectedAccountID);
  const destination = data.destinations.find(
    (item) => item.id === selectedDestinationID,
  );
  const target = draft || account;

  async function saveAccount() {
    if (!target?.name.trim()) return;
    await run("Guardar cuenta", async () => {
      await call("config_save", {
        collection: "accounts",
        item: { ...target, name: target.name.trim() },
      });
      if (credential)
        await call("credential_save", { id: target.id, value: credential });
      setSelectedAccountID(target.id);
      setDraft(null);
      setCredential("");
    });
  }
  async function inspect(title: string, action: () => Promise<unknown>) {
    await run(
      title,
      async () => {
        const value = await action();
        setResult(value);
        setResultTitle(title);
      },
      `${title} completado.`,
    );
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">SALIDAS DE LA BIBLIOTECA</p>
          <h1>Conectores</h1>
          <p>
            Cuentas locales y destinos declarados por tu proyecto de TypeScript.
          </p>
        </div>
        <Button
          icon={Plus}
          primary
          onClick={() => {
            const id = uniqueID("cuenta");
            setDraft({ id, name: "", provider: "notion", enabled: true });
            setSelectedAccountID(null);
            setCredential("");
          }}
        >
          Nueva cuenta
        </Button>
      </div>
      <div className="two-column">
        <section className="panel section-panel">
          <div className="panel-heading">
            <h2>Cuentas</h2>
            <span>{data.accounts.length}</span>
          </div>
          <div className="row-list">
            {data.accounts.map((item) => (
              <button
                type="button"
                key={item.id}
                className={`select-row ${selectedAccountID === item.id ? "selected" : ""}`}
                onClick={() => {
                  setSelectedAccountID(item.id);
                  setDraft(null);
                  setSelectedDestinationID(null);
                  setCredential("");
                }}
              >
                <span className="item-symbol">
                  {item.provider === "notion" ? "N" : "O"}
                </span>
                <span>
                  <strong>{item.name}</strong>
                  <small>
                    {item.provider === "notion" ? "Notion" : "Carpeta OKF"} ·{" "}
                    {item.enabled ? "Activa" : "Inactiva"}
                    {item.hasCredential ? " · Credencial guardada" : ""}
                  </small>
                </span>
              </button>
            ))}
            {!data.accounts.length && (
              <p className="empty-inline">
                Añade una cuenta para conectar un destino.
              </p>
            )}
          </div>
        </section>
        <section className="panel section-panel">
          <div className="panel-heading">
            <h2>
              {target
                ? draft
                  ? "Nueva cuenta"
                  : "Editar cuenta"
                : "Destinos del proyecto"}
            </h2>
          </div>
          {target ? (
            <div className="form-stack">
              <div className="field">
                <label htmlFor="account-name">Nombre</label>
                <input
                  id="account-name"
                  value={target.name}
                  onChange={(event) =>
                    setDraft({ ...target, name: event.target.value })
                  }
                  placeholder="Por ejemplo, Notion de trabajo"
                />
              </div>
              <div className="field">
                <label htmlFor="account-provider">Proveedor</label>
                <select
                  id="account-provider"
                  value={target.provider}
                  disabled={!draft || Boolean(account)}
                  onChange={(event) =>
                    setDraft({
                      ...target,
                      provider: event.target.value as Account["provider"],
                    })
                  }
                >
                  <option value="notion">Notion</option>
                  <option value="okf">Open Knowledge Format</option>
                </select>
              </div>
              {target.provider === "okf" ? (
                <div className="field">
                  <label>Carpeta autorizada</label>
                  <div className="inline-controls">
                    <input
                      value={target.folder || ""}
                      readOnly
                      placeholder="Elige una carpeta"
                    />
                    <Button
                      icon={FolderOpen}
                      onClick={() =>
                        void chooseFolder().then((path) => {
                          if (path) setDraft({ ...target, folder: path });
                        })
                      }
                    >
                      Elegir
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="field">
                  <label htmlFor="account-token">Token de integración</label>
                  <input
                    id="account-token"
                    type="password"
                    autoComplete="new-password"
                    value={credential}
                    onChange={(event) => setCredential(event.target.value)}
                    placeholder={
                      target.hasCredential
                        ? "Guardado; escribe para reemplazar"
                        : "Pega el token de acceso"
                    }
                  />
                  <small>
                    Se guarda localmente y nunca se muestra de nuevo.
                  </small>
                  {account?.hasCredential && (
                    <Button
                      icon={Trash2}
                      danger
                      onClick={() =>
                        void run(
                          "Quitar token",
                          () =>
                            call("credential_save", {
                              id: account.id,
                              value: "",
                            }),
                          undefined,
                          "¿Quitar el token guardado de esta cuenta?",
                        )
                      }
                    >
                      Quitar token guardado
                    </Button>
                  )}
                </div>
              )}
              <label className="toggle-row">
                <span>
                  <strong>Cuenta activa</strong>
                  <small>Los destinos vinculados podrán publicar.</small>
                </span>
                <input
                  type="checkbox"
                  checked={target.enabled}
                  onChange={(event) =>
                    setDraft({ ...target, enabled: event.target.checked })
                  }
                />
              </label>
              <div className="footer-actions">
                <Button
                  icon={Save}
                  primary
                  onClick={() => void saveAccount()}
                  disabled={
                    busy ||
                    !target.name.trim() ||
                    (target.provider === "okf" && !target.folder)
                  }
                >
                  Guardar cuenta
                </Button>
                {account && (
                  <Button
                    icon={Trash2}
                    danger
                    onClick={() =>
                      void run(
                        "Quitar cuenta",
                        () =>
                          call("config_remove", {
                            collection: "accounts",
                            id: account.id,
                          }),
                        undefined,
                        `¿Quitar la cuenta «${account.name}»?`,
                      )
                    }
                  >
                    Quitar
                  </Button>
                )}
              </div>
            </div>
          ) : (
            <p className="empty-inline">
              Selecciona una cuenta. Los destinos se definen en el proyecto y se
              muestran abajo.
            </p>
          )}
        </section>
      </div>
      <section className="panel section-panel destinations-panel">
        <div className="panel-heading">
          <div>
            <h2>Destinos</h2>
            <p>
              El código del proyecto define nombres, esquemas y plantillas. Aquí
              puedes inspeccionarlos y activarlos.
            </p>
          </div>
          <span>{data.destinations.length}</span>
        </div>
        <div className="destination-grid">
          {data.destinations.map((item) => (
            <button
              type="button"
              key={item.id}
              className={`destination-card ${selectedDestinationID === item.id ? "selected" : ""}`}
              onClick={() => {
                setSelectedDestinationID(item.id);
                setSelectedAccountID(null);
                setDraft(null);
                setResult(null);
              }}
            >
              <span className="item-symbol">
                {item.provider === "notion" ? "N" : "O"}
              </span>
              <strong>{item.name}</strong>
              <small>
                {item.description ||
                  `${item.provider.toUpperCase()} · ${data.accounts.find((account) => account.id === item.account)?.name || item.account}`}
              </small>
              <span className={`small-state ${item.enabled ? "enabled" : ""}`}>
                {item.enabled ? "Activo" : "Inactivo"}
              </span>
            </button>
          ))}
          {!data.destinations.length && (
            <div className="empty-inline">
              Todavía no hay destinos instalados. Elige un proyecto de recetas y
              compílalo.
            </div>
          )}
        </div>
        {destination && (
          <div className="destination-detail">
            <div className="section-line">
              <div>
                <strong>{destination.name}</strong>
                <p className="muted compact">
                  ID: {destination.id} · Cuenta: {destination.account}
                </p>
              </div>
              <Button
                onClick={() =>
                  void run(
                    destination.enabled
                      ? "Desactivar destino"
                      : "Activar destino",
                    () =>
                      call("config_save", {
                        collection: "destinations",
                        item: { ...destination, enabled: !destination.enabled },
                      }),
                  )
                }
              >
                {destination.enabled ? "Desactivar" : "Activar"}
              </Button>
            </div>
            <div className="detail-actions">
              <Button
                icon={ShieldCheck}
                onClick={() =>
                  void inspect("Validar destino", () =>
                    validateDestination(destination.id),
                  )
                }
              >
                Validar
              </Button>
              <Button
                icon={Search}
                onClick={() =>
                  void inspect("Descubrir recursos", () =>
                    discoverDestination(destination.id),
                  )
                }
              >
                Descubrir
              </Button>
              <select
                aria-label="Grabación para la vista previa"
                value={previewRecordingID}
                onChange={(event) => setPreviewRecordingID(event.target.value)}
              >
                <option value="">Nota de ejemplo</option>
                {data.recordings
                  .filter((recording) => recording.versions.length)
                  .map((recording) => (
                    <option key={recording.id} value={recording.id}>
                      {recording.title}
                    </option>
                  ))}
              </select>
              <Button
                icon={BookOpen}
                onClick={() =>
                  void inspect("Vista previa", () =>
                    previewDestination(
                      destination.id,
                      previewRecordingID || undefined,
                    ),
                  )
                }
              >
                Vista previa
              </Button>
            </div>
            <details className="code-disclosure">
              <summary>
                Configuración declarada <ChevronDown size={14} />
              </summary>
              <pre>{displayJSON(destination.configuration)}</pre>
            </details>
          </div>
        )}
        {result !== null && (
          <div className="result-panel">
            <div className="section-line">
              <strong>{resultTitle}</strong>
              <IconButton
                title="Cerrar resultado"
                onClick={() => setResult(null)}
              >
                <X size={15} />
              </IconButton>
            </div>
            <pre>{displayJSON(result)}</pre>
          </div>
        )}
      </section>
    </>
  );
}

function Resolvers({
  data,
  role,
  busy,
  run,
}: {
  data: Snapshot;
  role: Resolver["role"];
  busy: boolean;
  run: RunAction;
}) {
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [draft, setDraft] = useState<Resolver | null>(null);
  const [credential, setCredential] = useState("");
  const [downloadModel, setDownloadModel] = useState(
    data.settings.whisperModel,
  );
  const [nativeStatus, setNativeStatus] = useState<unknown>(
    data.native || null,
  );
  const resolvers = data.resolvers.filter((item) => item.role === role);
  const selected = resolvers.find((item) => item.id === selectedID);
  const target = draft || selected;
  async function saveResolver() {
    if (!target?.name.trim()) return;
    await run("Guardar resolutor", async () => {
      await call("config_save", {
        collection: "resolvers",
        item: { ...target, name: target.name.trim() },
      });
      if (credential)
        await call("credential_save", { id: target.id, value: credential });
      setSelectedID(target.id);
      setDraft(null);
      setCredential("");
    });
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">
            MOTORES DE {role === "stt" ? "TRANSCRIPCIÓN" : "LENGUAJE"}
          </p>
          <h1>{role === "stt" ? "STT" : "LLMs"}</h1>
          <p>
            {role === "stt"
              ? "El motor local es permanente. Puedes añadir motores remotos compatibles con OpenAI."
              : "Apple Intelligence se mantiene disponible. Añade servidores compatibles con OpenAI cuando los necesites."}
          </p>
        </div>
        <Button
          icon={Plus}
          primary
          onClick={() => {
            setDraft({
              id: uniqueID(role),
              name: "",
              role,
              local: false,
              enabled: true,
              url: "",
              model: "",
            });
            setSelectedID(null);
            setCredential("");
          }}
        >
          Añadir remoto
        </Button>
      </div>
      <div className="two-column">
        <section className="panel section-panel">
          <div className="panel-heading">
            <h2>Disponibles</h2>
            <span>{resolvers.length}</span>
          </div>
          <div className="row-list">
            {resolvers.map((item) => (
              <button
                type="button"
                key={item.id}
                className={`select-row ${selectedID === item.id ? "selected" : ""}`}
                onClick={() => {
                  setSelectedID(item.id);
                  setDraft(null);
                  setCredential("");
                }}
              >
                <span className="item-symbol">
                  {item.local ? (
                    <Sparkles size={17} />
                  ) : (
                    <ExternalLink size={16} />
                  )}
                </span>
                <span>
                  <strong>{item.name}</strong>
                  <small>
                    {item.local
                      ? "Local · permanente"
                      : item.url || "Servidor remoto"}{" "}
                    · {item.enabled ? "Activo" : "Inactivo"}
                  </small>
                </span>
              </button>
            ))}
          </div>
        </section>
        <section className="panel section-panel">
          <div className="panel-heading">
            <h2>
              {target
                ? target.local
                  ? "Motor local"
                  : draft && !selected
                    ? "Nuevo motor"
                    : "Configurar motor"
                : "Detalles"}
            </h2>
          </div>
          {target ? (
            <div className="form-stack">
              <div className="field">
                <label htmlFor="resolver-name">Nombre</label>
                <input
                  id="resolver-name"
                  value={target.name}
                  readOnly={target.local}
                  onChange={(event) =>
                    setDraft({ ...target, name: event.target.value })
                  }
                />
              </div>
              {!target.local && (
                <>
                  <div className="field">
                    <label htmlFor="resolver-url">URL del servidor</label>
                    <input
                      id="resolver-url"
                      type="url"
                      value={target.url || ""}
                      placeholder="https://…/v1"
                      onChange={(event) =>
                        setDraft({ ...target, url: event.target.value })
                      }
                    />
                  </div>
                  <div className="field">
                    <label htmlFor="resolver-model">Modelo</label>
                    <input
                      id="resolver-model"
                      value={target.model || ""}
                      onChange={(event) =>
                        setDraft({ ...target, model: event.target.value })
                      }
                    />
                  </div>
                  <div className="field">
                    <label htmlFor="resolver-token">Clave de acceso</label>
                    <input
                      id="resolver-token"
                      type="password"
                      autoComplete="new-password"
                      value={credential}
                      onChange={(event) => setCredential(event.target.value)}
                      placeholder={
                        target.hasCredential
                          ? "Guardada; escribe para reemplazar"
                          : "Opcional si tu servidor no la requiere"
                      }
                    />
                    <small>
                      La clave se guarda localmente y es de solo escritura en
                      esta vista.
                    </small>
                    {selected?.hasCredential && (
                      <Button
                        icon={Trash2}
                        danger
                        onClick={() =>
                          void run(
                            "Quitar clave",
                            () =>
                              call("credential_save", {
                                id: selected.id,
                                value: "",
                              }),
                            undefined,
                            "¿Quitar la clave guardada de este motor?",
                          )
                        }
                      >
                        Quitar clave guardada
                      </Button>
                    )}
                  </div>
                  <label className="toggle-row">
                    <span>
                      <strong>Activo</strong>
                      <small>Las recetas podrán seleccionarlo.</small>
                    </span>
                    <input
                      type="checkbox"
                      checked={target.enabled}
                      onChange={(event) =>
                        setDraft({ ...target, enabled: event.target.checked })
                      }
                    />
                  </label>
                  <div className="footer-actions">
                    <Button
                      icon={Save}
                      primary
                      disabled={
                        busy || !target.name.trim() || !target.url?.trim()
                      }
                      onClick={() => void saveResolver()}
                    >
                      Guardar
                    </Button>
                    {selected && (
                      <Button
                        icon={Trash2}
                        danger
                        onClick={() =>
                          void run(
                            "Quitar resolutor",
                            () =>
                              call("config_remove", {
                                collection: "resolvers",
                                id: selected.id,
                              }),
                            undefined,
                            `¿Quitar «${selected.name}»? Las recetas volverán al motor local.`,
                          )
                        }
                      >
                        Quitar
                      </Button>
                    )}
                  </div>
                </>
              )}
              {target.local && (
                <p className="muted">
                  Este motor forma parte de Escriba y permanece disponible para
                  las recetas.
                </p>
              )}
            </div>
          ) : (
            <p className="empty-inline">
              Selecciona un motor para ver su configuración.
            </p>
          )}
        </section>
      </div>
      <section className="panel section-panel native-panel">
        <div className="panel-heading">
          <div>
            <h2>Estado local</h2>
            <p>
              Consulta el proceso nativo y descarga el modelo de transcripción
              cuando haga falta.
            </p>
          </div>
          <Button
            icon={RefreshCw}
            onClick={() =>
              void run("Consultar motor nativo", async () =>
                setNativeStatus(
                  await call("native", {
                    method: "status",
                    params: { model: data.settings.whisperModel },
                  }),
                ),
              )
            }
          >
            Comprobar
          </Button>
        </div>
        <div className="status-grid">
          <div>
            <small>WHISPERKIT</small>
            <strong>
              {(nativeStatus as Snapshot["native"])?.whisper?.available
                ? "Disponible"
                : "Pendiente de comprobar"}
            </strong>
            <span>
              {String(
                (nativeStatus as Snapshot["native"])?.whisper?.model ||
                  data.settings.whisperModel,
              )}
            </span>
          </div>
          <div>
            <small>APPLE INTELLIGENCE</small>
            <strong>
              {(nativeStatus as Snapshot["native"])?.llm?.available
                ? "Disponible"
                : "No disponible"}
            </strong>
            <span>
              {String(
                (nativeStatus as Snapshot["native"])?.llm?.reason ||
                  "Modelo del sistema",
              )}
            </span>
          </div>
        </div>
        {role === "stt" && (
          <div className="download-row">
            <input
              aria-label="Modelo Whisper"
              value={downloadModel}
              onChange={(event) => setDownloadModel(event.target.value)}
            />
            <Button
              icon={Download}
              disabled={busy || !downloadModel.trim()}
              onClick={() =>
                void run("Descargar modelo", () =>
                  call("native", {
                    method: "downloadModel",
                    params: { model: downloadModel.trim() },
                  }),
                )
              }
            >
              Descargar modelo
            </Button>
          </div>
        )}
      </section>
    </>
  );
}

function Recipes({
  data,
  busy,
  run,
  chooseFolder,
}: {
  data: Snapshot;
  busy: boolean;
  run: RunAction;
  chooseFolder: () => Promise<string | null>;
}) {
  const [selectedID, setSelectedID] = useState<string | null>(
    data.settings.defaultRecipeId || data.recipes[0]?.id || null,
  );
  const [draft, setDraft] = useState<Recipe | null>(null);
  const [schema, setSchema] = useState<JSONObject | undefined>(undefined);
  const [schemaError, setSchemaError] = useState<string | null>(null);
  const [source, setSource] = useState<string | null>(null);
  const [showSource, setShowSource] = useState(false);
  const selected = data.recipes.find((item) => item.id === selectedID);
  const recipe = draft || selected;
  const schemaID =
    recipe?.base ||
    (recipe && data.recipes.some((item) => item.id === recipe.id)
      ? recipe.id
      : data.recipes.find((item) => item.name === "Por defecto")?.id ||
        data.settings.defaultRecipeId);
  const schemaProgram = data.recipes.find(
    (item) => item.id === schemaID,
  )?.bundle;
  const schemaLists = JSON.stringify({
    resolvers: data.resolvers,
    destinations: data.destinations.map(
      ({ id, name, provider, enabled, account }) => ({
        id,
        name,
        provider,
        enabled,
        account,
      }),
    ),
    accounts: data.accounts.map(({ id, enabled }) => ({ id, enabled })),
    recipes: data.recipes.map(({ id, name, kind }) => ({ id, name, kind })),
    language: data.settings.language,
  });
  useEffect(() => {
    setSchema(undefined);
    setSchemaError(null);
    if (!recipe || !schemaID) return;
    let active = true;
    void getRecipeSchema(schemaID)
      .then((value) => {
        if (active) setSchema(value);
      })
      .catch((error) => {
        if (active) setSchemaError(errorText(error));
      });
    return () => {
      active = false;
    };
  }, [schemaID, schemaProgram, schemaLists]);
  async function saveRecipe() {
    if (!recipe?.name.trim()) return;
    await run("Guardar receta", async () => {
      await call("config_save", {
        collection: "recipes",
        item: { ...recipe, name: recipe.name.trim() },
      });
      setSelectedID(recipe.id);
      setDraft(null);
    });
  }
  async function projectAction() {
    try {
      const path = await chooseFolder();
      if (!path) return;
      await run("Elegir proyecto", async () => {
        await call("project_init", { path });
        await call("settings_save", { settings: { projectPath: path } });
        await rebuildProject();
      });
    } catch (failure) {
      window.alert(errorText(failure));
    }
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">AUTOMATIZACIÓN</p>
          <h1>Recetas</h1>
          <p>
            Elige la receta por defecto. Los parámetros se guardan por receta.
          </p>
        </div>
        <Button
          icon={Plus}
          primary
          onClick={() => {
            setDraft({
              id: uniqueID("receta"),
              name: "",
              kind: "form",
              values: {},
              base: selected?.kind === "code" ? selected.id : undefined,
            });
            setSelectedID(null);
          }}
        >
          Nueva de formulario
        </Button>
      </div>
      <div className="project-bar panel">
        <div>
          <small>PROYECTO DE CÓDIGO</small>
          <strong>{data.settings.projectPath || "Sin proyecto elegido"}</strong>
        </div>
        <div className="heading-actions">
          <Button icon={FolderOpen} onClick={() => void projectAction()}>
            {data.settings.projectPath ? "Cambiar" : "Elegir e inicializar"}
          </Button>
          <Button
            icon={RefreshCw}
            disabled={!data.settings.projectPath || busy}
            onClick={() =>
              void run("Compilar proyecto", async () => {
                await call("project_init", { path: data.settings.projectPath });
                await rebuildProject();
              })
            }
          >
            Compilar
          </Button>
          {data.settings.projectPath && (
            <Button
              icon={ExternalLink}
              onClick={() =>
                void run("Abrir proyecto", () =>
                  call("reveal", { path: data.settings.projectPath }),
                )
              }
            >
              Abrir carpeta
            </Button>
          )}
        </div>
      </div>
      <p className="empty-inline">
        Tras importar una biblioteca, elige aquí la carpeta original del
        proyecto y pulsa Compilar para preparar sus dependencias y recuperar las
        recetas de código. Si el proyecto usa otros paquetes npm, deben estar
        instalados en esa carpeta.
      </p>
      <div className="two-column recipes-grid">
        <section className="panel section-panel">
          <div className="panel-heading">
            <h2>Instaladas</h2>
            <span>{data.recipes.length}</span>
          </div>
          <div className="row-list">
            {data.recipes.map((item) => (
              <button
                type="button"
                key={item.id}
                className={`select-row ${selectedID === item.id ? "selected" : ""}`}
                onClick={() => {
                  setSelectedID(item.id);
                  setDraft(null);
                  setShowSource(false);
                }}
              >
                <span className="item-symbol">
                  {item.kind === "code" ? "{ }" : <BookOpen size={16} />}
                </span>
                <span>
                  <strong>
                    {item.name}{" "}
                    {data.settings.defaultRecipeId === item.id && (
                      <em className="default-mark">Por defecto</em>
                    )}
                  </strong>
                  <small>
                    {item.kind === "code" ? "Código" : "Formulario"}
                    {item.error
                      ? ` · ${item.error}`
                      : item.description
                        ? ` · ${item.description}`
                        : ""}
                  </small>
                </span>
              </button>
            ))}
            {!data.recipes.length && (
              <p className="empty-inline">
                Elige o inicializa un proyecto para cargar recetas.
              </p>
            )}
          </div>
        </section>
        <section className="panel section-panel recipe-editor">
          <div className="panel-heading">
            <h2>
              {recipe ? recipe.name || "Nueva receta" : "Selecciona una receta"}
            </h2>
            {recipe && (
              <span>{recipe.kind === "code" ? "CÓDIGO" : "FORMULARIO"}</span>
            )}
          </div>
          {recipe ? (
            <div className="form-stack">
              <div className="field">
                <label htmlFor="recipe-name">Nombre</label>
                <input
                  id="recipe-name"
                  value={recipe.name}
                  readOnly={recipe.kind === "code"}
                  onChange={(event) =>
                    setDraft({ ...recipe, name: event.target.value })
                  }
                />
              </div>
              {recipe.description && (
                <p className="muted compact">{recipe.description}</p>
              )}
              {recipe.error && (
                <div className="inline-error">
                  <CircleAlert size={15} />
                  {recipe.error}
                </div>
              )}
              {recipe.kind === "form" && (
                <div className="field">
                  <label htmlFor="recipe-base">Basada en</label>
                  <select
                    id="recipe-base"
                    value={recipe.base || ""}
                    onChange={(event) =>
                      setDraft({
                        ...recipe,
                        base: event.target.value || undefined,
                      })
                    }
                  >
                    <option value="">Por defecto (serie)</option>
                    {data.recipes
                      .filter((item) => item.kind === "code")
                      .map((item) => (
                        <option key={item.id} value={item.id}>
                          {item.name}
                        </option>
                      ))}
                  </select>
                </div>
              )}
              <div className="section-line">
                <strong>Parámetros</strong>
                <small>Declarados por el esquema Zod de la receta.</small>
              </div>
              {schemaError && (
                <p role="alert">
                  {schemaError} Revisa la carpeta del proyecto y pulsa Compilar.
                  Los valores guardados se conservan.
                </p>
              )}
              <SchemaForm
                schema={schema}
                values={recipe.values}
                onChange={(values) => setDraft({ ...recipe, values })}
                disabled={busy || !schema || !!schemaError}
              />
              <div className="footer-actions">
                <Button
                  icon={Save}
                  primary
                  onClick={() => void saveRecipe()}
                  disabled={busy || !recipe.name.trim()}
                >
                  Guardar valores
                </Button>
                {data.settings.defaultRecipeId !== recipe.id && (
                  <Button
                    icon={Check}
                    onClick={() =>
                      void run("Elegir receta por defecto", () =>
                        call("settings_save", {
                          settings: { defaultRecipeId: recipe.id },
                        }),
                      )
                    }
                  >
                    Usar por defecto
                  </Button>
                )}
              </div>
              <div className="secondary-actions">
                <Button
                  icon={Plus}
                  onClick={() => {
                    setDraft({
                      ...recipe,
                      id: uniqueID("receta"),
                      name: `${recipe.name} copia`,
                      kind: "form",
                      base: recipe.kind === "code" ? recipe.id : recipe.base,
                    });
                    setSelectedID(null);
                  }}
                >
                  {" "}
                  {recipe.kind === "code"
                    ? "Guardar como formulario"
                    : "Duplicar"}
                </Button>
                {recipe.kind === "form" &&
                  selected &&
                  selected.id !== data.settings.defaultRecipeId && (
                    <Button
                      icon={Trash2}
                      danger
                      onClick={() =>
                        void run(
                          "Quitar receta",
                          () =>
                            call("config_remove", {
                              collection: "recipes",
                              id: recipe.id,
                            }),
                          undefined,
                          `¿Quitar la receta «${recipe.name}»?`,
                        )
                      }
                    >
                      Quitar
                    </Button>
                  )}
                {recipe.kind === "code" && recipe.entry && (
                  <Button
                    icon={showSource ? X : BookOpen}
                    onClick={() => {
                      if (showSource) {
                        setShowSource(false);
                        return;
                      }
                      void run("Leer fuente", async () => {
                        const response = await call<{ source: string }>(
                          "project_read",
                          { entry: recipe.entry },
                        );
                        setSource(response.source);
                        setShowSource(true);
                      });
                    }}
                  >
                    {showSource ? "Ocultar fuente" : "Ver fuente"}
                  </Button>
                )}
              </div>
              {showSource && <pre className="source-view">{source}</pre>}
            </div>
          ) : (
            <p className="empty-inline">
              Selecciona una receta de la lista o crea una de formulario.
            </p>
          )}
        </section>
      </div>
    </>
  );
}

function LogView({
  logs,
  recordings,
  run,
}: {
  logs: LogEntry[];
  recordings: Recording[];
  run: RunAction;
}) {
  const [level, setLevel] = useState("all");
  const [query, setQuery] = useState("");
  const [recordingID, setRecordingID] = useState("all");
  const [history, setHistory] = useState<RuntimeHistory[]>([]);
  const [traces, setTraces] = useState<RecipeTrace[]>([]);
  const [historyError, setHistoryError] = useState<string | null>(null);
  useEffect(() => {
    if (DEMO || !desktop) return;
    let active = true;
    const refresh = () =>
      Promise.all([
        call<RuntimeHistory[]>("runtime_history"),
        call<RecipeTrace[]>("trace_list"),
      ])
        .then(([jobs, runs]) => {
          if (active) {
            setHistory(jobs);
            setTraces(runs);
            setHistoryError(null);
          }
        })
        .catch((error) => {
          if (active) setHistoryError(errorText(error));
        });
    void refresh();
    const timer = window.setInterval(() => void refresh(), 15000);
    const stop = subscribeJobs(() => void refresh(), setHistoryError);
    return () => {
      active = false;
      window.clearInterval(timer);
      stop();
    };
  }, []);

  const filtered = logs
    .filter(
      (entry) =>
        (level === "all" || entry.level === level) &&
        (recordingID === "all" || entry.recordingId === recordingID) &&
        `${entry.message} ${entry.recipeId || ""}`
          .toLocaleLowerCase("es")
          .includes(query.toLocaleLowerCase("es")),
    )
    .sort((a, b) => b.at.localeCompare(a.at));
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">ACTIVIDAD DEL MOTOR</p>
          <h1>Registro</h1>
          <p>Eventos de proceso, publicaciones y errores con su contexto.</p>
        </div>
        <Button
          icon={Trash2}
          danger
          onClick={() =>
            void run(
              "Vaciar registro",
              () => call("log_clear"),
              undefined,
              "¿Vaciar el registro de esta instalación?",
            )
          }
        >
          Vaciar
        </Button>
      </div>
      {historyError && <p role="alert">{historyError}</p>}
      <section className="panel section-panel">
        <h2>Trabajos y reintentos</h2>
        {!history.length && (
          <p className="empty-inline">Aún no hay trabajos.</p>
        )}
        {history
          .filter(
            (job) => recordingID === "all" || job.recordingId === recordingID,
          )
          .sort((a, b) => b.createdAt - a.createdAt)
          .slice(0, 200)
          .map((job) => (
            <div className="log-row" key={job.id}>
              <time>{shortDate(new Date(job.createdAt).toISOString())}</time>
              <div>
                <strong>
                  {recordings.find((record) => record.id === job.recordingId)
                    ?.title || job.recordingId}
                </strong>
                <p>
                  {job.stage} · Intento {job.attempt}
                </p>
                {job.state === "retry" && (
                  <p>
                    Esperando al servicio. Puedes corregir su configuración
                    mientras espera.
                  </p>
                )}
                {job.error && <p role="alert">{errorText(job.error)}</p>}
              </div>
            </div>
          ))}
      </section>
      <section className="panel section-panel">
        <h2>Ejecuciones de recetas</h2>
        {!traces.length && (
          <p className="empty-inline">
            Las ejecuciones y pruebas aparecerán aquí.
          </p>
        )}
        {traces
          .filter(
            (trace) =>
              recordingID === "all" || trace.recordingId === recordingID,
          )
          .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
          .slice(0, 200)
          .map((trace) => (
            <details key={trace.id} className="section-panel">
              <summary>
                {shortDate(trace.startedAt)} ·{" "}
                {recordings.find((record) => record.id === trace.recordingId)
                  ?.title || trace.recordingId}{" "}
                · {trace.dryRun ? "Prueba sin guardar" : "Ejecución"}
                {trace.error ? " · Error" : ""}
              </summary>
              {trace.error && <p role="alert">{errorText(trace.error)}</p>}
              <ol>
                {trace.steps.map((step, index) => (
                  <li key={index}>
                    <strong>
                      {(
                        {
                          transcribe: "Transcribir",
                          summarize: "Resumir",
                          ask: "Preguntar",
                          save: "Guardar",
                          publish: "Publicar",
                          process: "Procesar receta",
                          log: "Registro",
                        } as Record<string, string>
                      )[step.capability] || step.capability}
                    </strong>{" "}
                    · {step.seconds.toFixed(2)} s{" "}
                    {step.origin && `· ${step.origin}`}
                    {step.error && <p role="alert">{errorText(step.error)}</p>}
                  </li>
                ))}
              </ol>
              {trace.result && (
                <details>
                  <summary>Resultado de la receta</summary>
                  <pre className="source-view">
                    {JSON.stringify(trace.result, null, 2)}
                  </pre>
                </details>
              )}
            </details>
          ))}
      </section>
      <section className="panel log-panel">
        <div className="log-filters">
          <div className="searchbox">
            <Search size={16} />
            <input
              aria-label="Buscar en el registro"
              placeholder="Buscar mensajes"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>
          <select
            aria-label="Filtrar nivel"
            value={level}
            onChange={(event) => setLevel(event.target.value)}
          >
            <option value="all">Todos los niveles</option>
            <option value="info">Información</option>
            <option value="warn">Avisos</option>
            <option value="error">Errores</option>
          </select>
          <select
            aria-label="Filtrar grabación"
            value={recordingID}
            onChange={(event) => setRecordingID(event.target.value)}
          >
            <option value="all">Todas las grabaciones</option>
            {recordings.map((item) => (
              <option key={item.id} value={item.id}>
                {item.title}
              </option>
            ))}
          </select>
          <span>{filtered.length} eventos</span>
        </div>
        <div className="log-rows">
          {filtered.map((entry) => (
            <div className="log-row" key={entry.id}>
              <time>{shortDate(entry.at)}</time>
              <span className={`log-level ${entry.level}`}>
                {entry.level === "warn"
                  ? "AVISO"
                  : entry.level === "error"
                    ? "ERROR"
                    : "INFO"}
              </span>
              <div>
                <strong>{entry.message}</strong>
                {(entry.recordingId || entry.recipeId) && (
                  <small>
                    {entry.recordingId &&
                      `Grabación: ${recordings.find((item) => item.id === entry.recordingId)?.title || entry.recordingId}`}
                    {entry.recipeId && ` · Receta: ${entry.recipeId}`}
                  </small>
                )}
              </div>
            </div>
          ))}
          {!filtered.length && (
            <div className="empty-list">
              <ListFilter size={22} />
              <strong>Sin eventos</strong>
              <span>Cambia los filtros o espera actividad nueva.</span>
            </div>
          )}
        </div>
      </section>
    </>
  );
}

function SettingsView({
  data,
  busy,
  run,
  chooseFolder,
  retryWatchScan,
  authorizeWatchedFolder,
  openPrivacySettings,
}: {
  data: Snapshot;
  busy: boolean;
  run: RunAction;
  chooseFolder: () => Promise<string | null>;
  retryWatchScan: () => Promise<void>;
  authorizeWatchedFolder: (
    options: WatchAuthorization,
  ) => Promise<WatchedFolder | null>;
  openPrivacySettings: () => Promise<void>;
}) {
  const [settings, setSettings] = useState<Settings>(data.settings);
  const [watchName, setWatchName] = useState("");
  const [watchStyle, setWatchStyle] =
    useState<NonNullable<WatchedFolder["style"]>>("any");
  const [migrationPath, setMigrationPath] = useState<string | null>(null);
  const [migrationSettings, setMigrationSettings] = useState<string | null>(
    null,
  );
  const [migrationReport, setMigrationReport] = useState<{
    recordings: number;
    audioMissing: number;
    settingsImported: boolean;
  } | null>(null);

  const settingsRevision = JSON.stringify(data.settings);
  useEffect(() => setSettings(data.settings), [settingsRevision]);
  async function persist(patch: Partial<Settings>) {
    await run("Guardar ajustes", () =>
      call("settings_save", { settings: patch }),
    );
  }
  async function addFolder() {
    const folder = await authorizeWatchedFolder({
      name: watchName.trim() || undefined,
      style: watchStyle,
    });
    if (folder) setWatchName("");
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <p className="eyebrow">PREFERENCIAS LOCALES</p>
          <h1>Ajustes</h1>
          <p>Configuración de esta instalación y carpetas que se vigilan.</p>
        </div>
      </div>
      <div className="settings-grid">
        <section className="panel section-panel">
          <div className="panel-heading">
            <h2>General</h2>
          </div>
          <div className="form-stack">
            <div className="field">
              <label htmlFor="setting-theme">Apariencia</label>
              <select
                id="setting-theme"
                value={settings.theme}
                onChange={(event) => {
                  const theme = event.target.value as Settings["theme"];
                  setSettings({ ...settings, theme });
                  void persist({ theme });
                }}
              >
                <option value="system">Seguir el sistema</option>
                <option value="light">Clara</option>
                <option value="dark">Oscura</option>
              </select>
            </div>
            <div className="field">
              <label htmlFor="setting-language">Idioma de transcripción</label>
              <select
                id="setting-language"
                value={settings.language}
                onChange={(event) => {
                  const language = event.target.value;
                  setSettings({ ...settings, language });
                  void persist({ language });
                }}
              >
                <option value="es">Español</option>
                <option value="en">Inglés</option>
                <option value="auto">Detectar</option>
              </select>
            </div>
            <div className="field">
              <label htmlFor="setting-model">Modelo Whisper</label>
              <input
                id="setting-model"
                value={settings.whisperModel}
                onChange={(event) =>
                  setSettings({ ...settings, whisperModel: event.target.value })
                }
                onBlur={() => {
                  if (
                    settings.whisperModel.trim() !== data.settings.whisperModel
                  )
                    void persist({
                      whisperModel: settings.whisperModel.trim(),
                    });
                }}
              />
            </div>
            <label className="toggle-row">
              <span>
                <strong>Procesar automáticamente</strong>
                <small>Al importar o encontrar una grabación nueva.</small>
              </span>
              <input
                type="checkbox"
                checked={settings.autoProcess}
                onChange={(event) => {
                  const autoProcess = event.target.checked;
                  setSettings({ ...settings, autoProcess });
                  void persist({ autoProcess });
                }}
              />
            </label>
            <label className="toggle-row">
              <span>
                <strong>Abrir al iniciar sesión</strong>
                <small>Inicia Escriba con el escritorio.</small>
              </span>
              <input
                type="checkbox"
                checked={settings.launchAtLogin}
                onChange={(event) => {
                  const launchAtLogin = event.target.checked;
                  setSettings({ ...settings, launchAtLogin });
                  void persist({ launchAtLogin });
                }}
              />
            </label>
          </div>
        </section>
        <section className="panel section-panel">
          <div className="panel-heading">
            <div>
              <h2>Carpetas vigiladas</h2>
              <p>
                Selecciona cada carpeta en el panel de macOS para guardar su
                autorización. Acceso total al disco es una alternativa opcional
                si macOS sigue denegando la lectura.
              </p>
            </div>
          </div>
          <div className="folder-list">
            {settings.watchedFolders.map((folder) => (
              <div className="folder-row" key={folder.id}>
                <FolderOpen size={18} />
                <div>
                  <strong>{folder.name}</strong>
                  <small title={folder.path}>{folder.path}</small>
                  {data.watchIssues?.some(
                    (issue) => issue.folderId === folder.id,
                  ) && (
                    <small className="folder-issue" role="alert">
                      <CircleAlert size={12} /> No se puede leer esta carpeta
                    </small>
                  )}
                </div>
                <select
                  aria-label={`Formato de ${folder.name}`}
                  value={folder.style || "any"}
                  onChange={(event) =>
                    void persist({
                      watchedFolders: settings.watchedFolders.map((item) =>
                        item.id === folder.id
                          ? {
                              ...item,
                              style: event.target.value as NonNullable<
                                WatchedFolder["style"]
                              >,
                            }
                          : item,
                      ),
                    })
                  }
                >
                  <option value="any">Cualquier audio</option>
                  <option value="justPressRecord">Just Press Record</option>
                  <option value="voiceMemos">Notas de Voz</option>
                </select>
                <input
                  type="checkbox"
                  aria-label={`Vigilar ${folder.name}`}
                  checked={folder.enabled}
                  onChange={(event) =>
                    void persist({
                      watchedFolders: settings.watchedFolders.map((item) =>
                        item.id === folder.id
                          ? { ...item, enabled: event.target.checked }
                          : item,
                      ),
                    })
                  }
                />
                <IconButton
                  danger
                  title={`Quitar ${folder.name}`}
                  onClick={() =>
                    void run(
                      "Quitar carpeta vigilada",
                      () =>
                        call("settings_save", {
                          settings: {
                            watchedFolders: settings.watchedFolders.filter(
                              (item) => item.id !== folder.id,
                            ),
                          },
                        }),
                      undefined,
                      `¿Dejar de vigilar «${folder.name}»?`,
                    )
                  }
                >
                  <Trash2 size={16} />
                </IconButton>
                <div className="folder-authorization">
                  <Button
                    disabled={busy}
                    onClick={() =>
                      void authorizeWatchedFolder({ folderId: folder.id })
                    }
                  >
                    {folder.authorizationSaved
                      ? "Volver a autorizar"
                      : "Autorizar carpeta"}
                  </Button>
                </div>
              </div>
            ))}
            {!settings.watchedFolders.length && (
              <p className="empty-inline">No hay carpetas vigiladas.</p>
            )}
          </div>
          <div className="folder-add">
            <input
              aria-label="Nombre de la carpeta nueva"
              value={watchName}
              onChange={(event) => setWatchName(event.target.value)}
              placeholder="Nombre opcional"
            />
            <select
              aria-label="Formato de la carpeta nueva"
              value={watchStyle}
              onChange={(event) =>
                setWatchStyle(
                  event.target.value as NonNullable<WatchedFolder["style"]>,
                )
              }
            >
              <option value="any">Cualquier audio</option>
              <option value="justPressRecord">Just Press Record</option>
              <option value="voiceMemos">Notas de Voz</option>
            </select>
            <Button
              icon={Plus}
              onClick={() => void addFolder()}
              disabled={busy}
            >
              Seleccionar carpeta…
            </Button>
          </div>
          <div className="footer-actions">
            <Button
              icon={RefreshCw}
              onClick={() => void retryWatchScan()}
              disabled={busy}
            >
              Escanear ahora
            </Button>
            <Button
              disabled={busy}
              onClick={() => void openPrivacySettings()}
            >
              Acceso total al disco…
            </Button>
          </div>
        </section>
      </div>
      <section className="panel section-panel">
        <h2>Notificaciones</h2>
        <label>
          <input
            type="checkbox"
            checked={settings.notifyEveryNote !== false}
            onChange={(event) => {
              const notifyEveryNote = event.target.checked;
              setSettings({ ...settings, notifyEveryNote });
              void persist({ notifyEveryNote });
            }}
          />{" "}
          Avisar al terminar cada nota
        </label>
        <p>Los problemas se notifican siempre que el permiso esté concedido.</p>
        <Button
          onClick={() =>
            void run(
              "Comprobar notificaciones",
              () => call("notification_permission"),
              "Notificación de prueba enviada. Si no aparece, revisa Escriba en Ajustes del Sistema → Notificaciones.",
            )
          }
        >
          Comprobar notificaciones
        </Button>
      </section>
      <section className="panel section-panel">
        <h2>Importar biblioteca anterior</h2>
        <p>
          Elige la carpeta de Escriba que contiene library.sqlite. Se copian las
          notas y el audio; la biblioteca de origen se conserva.
        </p>
        <div className="form-stack">
          <Button
            icon={FolderOpen}
            onClick={() =>
              void run("Elegir biblioteca", async () =>
                setMigrationPath(await chooseFolder()),
              )
            }
          >
            Elegir biblioteca
          </Button>
          {migrationPath && <p>{migrationPath}</p>}
          <Button
            icon={FileDown}
            onClick={() =>
              void run("Elegir preferencias", async () => {
                const path = await open({
                  title: "Preferencias anteriores (opcional)",
                  multiple: false,
                  filters: [{ name: "Preferencias", extensions: ["plist"] }],
                });
                if (typeof path === "string") setMigrationSettings(path);
              })
            }
          >
            Elegir preferencias opcionales
          </Button>
          {migrationSettings && (
            <p>
              {migrationSettings}{" "}
              <Button onClick={() => setMigrationSettings(null)}>
                Quitar preferencias
              </Button>
            </p>
          )}
          <Button
            primary
            disabled={!migrationPath || busy}
            onClick={() =>
              void run("Importar biblioteca", async () => {
                setMigrationReport(
                  await call("library_import", {
                    path: migrationPath,
                    settingsPath: migrationSettings || undefined,
                  }),
                );
              })
            }
          >
            Importar biblioteca
          </Button>
          {migrationReport && (
            <ol>
              <li>
                En Recetas, selecciona la carpeta original del proyecto y pulsa
                Compilar para recuperar el código. Los paquetes instalados por
                la app anterior se regeneran desde ese proyecto.
              </li>
              <li>
                En Conectores, revisa cada cuenta, vuelve a introducir sus
                credenciales o elige su carpeta y actívala. Después revisa y
                activa sus destinos.
              </li>
              <li>
                En STT y LLMs, revisa los servicios importados,
                configura sus credenciales y actívalos. Confirma la receta por
                defecto antes de reanudar notas pendientes.
              </li>
            </ol>
          )}
          {migrationReport && (
            <p role="status">
              {migrationReport.recordings} grabaciones importadas.{" "}
              {migrationReport.audioMissing} sin audio disponible.
              {migrationReport.settingsImported
                ? " Preferencias importadas."
                : ""}{" "}
              Configura las credenciales en Conectores, STT y LLMs.
            </p>
          )}
        </div>
      </section>
      <section className="panel section-panel storage-panel">
        <div className="panel-heading">
          <h2>Almacenamiento</h2>
        </div>
        <p>
          <span className="muted">Biblioteca local</span>
          <strong>{data.dataPath}</strong>
        </p>
        {settings.projectPath && (
          <p>
            <span className="muted">Proyecto de recetas</span>
            <strong>{settings.projectPath}</strong>
          </p>
        )}
      </section>
    </>
  );
}
