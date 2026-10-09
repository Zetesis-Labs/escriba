import { getCurrentWebview } from "@tauri-apps/api/webview";
import { AudioLines, CircleStop, Ellipsis, FolderPlus, History, Mic, Users, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent } from "react";
import { call, desktop, native, recordingDetail } from "../api";
import { Pane } from "../app/Pane";
import { audioExtensions, fileName, importNotice, importPlan } from "../core/inbox";
import { librarySummary, rowActionText, speakers } from "../core/presentation";
import { Button, ContentUnavailable, PopupButton, Sheet, Spinner, TextField, ToolbarButton, ToolbarMenu } from "../mac/controls";
import { alertMessage, chooseFiles, confirmDestructive, errorText, header, item, popupMenu, separator, submenu, type MenuEntry } from "../mac/native";
import type { Account, Destination, JobState, Recording, Snapshot } from "../types";
import { currentVersion, currentVersionLabel, isPublished, libraryRecordings, liveDestinations, originName, providerLabel, versionsInOrder, versionTitle } from "./model";
import * as operations from "./operations";
import { displayTitle, RecordingRow } from "./RecordingRow";
import { TranscriptDetail } from "./TranscriptDetail";
import { startRecording, stopRecording } from "../recording/useRecording";
import "./library.css";

type Rename = { recording: Recording; speaker: string; name: string };

function revisionOf(recording: Recording) {
  return JSON.stringify([
    recording.status,
    recording.error ?? null,
    recording.audioPath,
    recording.currentVersionId ?? null,
    recording.versions.map((version) => [version.id, version.digest?.title ?? null, version.digest?.summary?.length ?? 0, Boolean(version.data)]),
    recording.publications.map((publication) => [publication.destinationId, publication.updatedAt, publication.error ?? null]),
  ]);
}

function useRecordingDetail(recording: Recording | null) {
  const [detail, setDetail] = useState<Recording | null>(null);
  const id = recording?.id;
  const revision = recording ? revisionOf(recording) : "";
  useEffect(() => {
    if (!recording) return setDetail(null);
    if (!desktop) return setDetail(recording);
    let current = true;
    void recordingDetail(recording.id)
      .then((full) => current && setDetail(full))
      .catch(() => current && setDetail(null));
    return () => {
      current = false;
    };
  }, [id, revision]);
  return detail && detail.id === id ? detail : null;
}

export function LibraryView({
  data,
  jobs,
  refresh,
  active,
  isRecording,
}: {
  data: Snapshot;
  jobs: JobState[];
  refresh: () => Promise<void>;
  active: boolean;
  isRecording: boolean;
}) {
  const recordings = useMemo(() => libraryRecordings(data), [data]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [dropTargeted, setDropTargeted] = useState(false);
  const [reprocessing, setReprocessing] = useState<Recording | null>(null);
  const [rename, setRename] = useState<Rename | null>(null);
  const selected = recordings.find((recording) => recording.id === selectedId) ?? null;
  const detail = useRecordingDetail(selected);
  const live = liveDestinations(data.destinations, data.accounts);
  const folders = data.settings.watchedFolders;
  const canSummarize = data.native?.llm?.available !== false;
  const minute = useMemo(() => Math.floor(Date.now() / 60_000), [data]);
  const jobFor = (recording: Recording) => jobs.find((job) => job.recordingId === recording.id);

  const perform = useCallback(
    async (work: () => Promise<unknown>) => {
      try {
        await work();
      } catch (failure) {
        await alertMessage("No se pudo", errorText(failure));
      } finally {
        await refresh();
      }
    },
    [refresh],
  );

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 8000);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const add = useCallback(
    async (paths: string[], recipeId?: string) => {
      const plan = importPlan(paths);
      let added: string[] = [];
      const failed: string[] = [];
      if (plan.accepted.length)
        try {
          const created = await call<Recording[]>("import_audio", { paths: plan.accepted, recipeId });
          added = created.map((recording) => fileName(recording.source));
        } catch (failure) {
          failed.push(...plan.accepted.map(fileName));
          await alertMessage("No se pudo", errorText(failure));
        }
      setNotice(importNotice({ added, rejected: plan.rejected, failed }));
      await refresh();
    },
    [refresh],
  );

  useEffect(() => {
    if (!desktop || !active) return;
    let stop: (() => void) | undefined;
    void getCurrentWebview()
      .onDragDropEvent((event) => {
        if (event.payload.type === "enter" || event.payload.type === "over") setDropTargeted(true);
        else if (event.payload.type === "leave") setDropTargeted(false);
        else {
          setDropTargeted(false);
          void add(event.payload.paths);
        }
      })
      .then((unlisten) => {
        stop = unlisten;
      });
    return () => stop?.();
  }, [add, active]);

  const recipeChoices = (choose: (recipeId?: string) => void): MenuEntry[] => [
    header("Con la receta"),
    ...data.recipes.map((recipe) =>
      recipe.id === data.settings.defaultRecipeId ? item(`${recipe.name} (por defecto)`, () => choose()) : item(recipe.name, () => choose(recipe.id)),
    ),
  ];
  const chooseAudio = async (recipeId?: string) => {
    const paths = await chooseFiles(audioExtensions);
    if (paths.length) await add(paths, recipeId);
  };
  const record = (recipeId?: string) => perform(() => startRecording(recipeId));
  const stop = () => perform(stopRecording);

  const publishEntries = (recording: Recording): MenuEntry[] => {
    if (!live.length) return [];
    const entries = live.map((destination) => {
      const publication = recording.publications.find((candidate) => candidate.destinationId === destination.id && isPublished(candidate));
      const kind = providerLabel(destination.provider);
      if (!publication) return item(`Publicar en ${destination.name}`, () => void perform(() => operations.publish(recording, destination.id)));
      const url = typeof publication.receipt.url === "string" ? publication.receipt.url : null;
      const file = okfFile(destination, data.accounts, publication.receipt);
      return submenu(destination.name, [
        ...(url ? [item(`Abrir en ${kind}`, () => void perform(() => operations.openURL(url)))] : []),
        ...(file ? [item("Mostrar en Finder", () => void perform(() => operations.reveal(file)))] : []),
        item(`Actualizar en ${kind}`, () => void perform(() => operations.publish(recording, destination.id))),
        separator,
        item(`Borrar de ${kind}…`, () => void unpublish(recording, destination)),
      ]);
    });
    return [...entries, separator];
  };

  const unpublish = async (recording: Recording, destination: Destination) => {
    const confirmed = await confirmDestructive(
      `¿Borrar ${displayTitle(recording)} de ${destination.name}?`,
      rowActionText.unpublish(destination.provider),
      `Borrar de ${destination.name}`,
    );
    if (confirmed) await perform(() => operations.unpublish(recording, destination.id));
  };
  const removeAudio = async (recording: Recording) => {
    const originalExists = await native("fileStatus", { path: recording.source }).then(
      () => true,
      () => false,
    );
    const confirmed = await confirmDestructive(`¿Quitar el audio de ${displayTitle(recording)}?`, rowActionText.removeAudio(originalExists), "Quitar la copia de audio");
    if (confirmed) await perform(() => operations.removeAudio(recording));
  };
  const forget = async (recording: Recording) => {
    const confirmed = await confirmDestructive(`¿Borrar ${displayTitle(recording)} de la biblioteca?`, rowActionText.discard, "Borrar grabación y transcripciones");
    if (!confirmed) return;
    if (selectedId === recording.id) setSelectedId(null);
    await perform(() => operations.forget(recording));
  };

  const rowMenu = (recording: Recording): MenuEntry[] => [
    ...publishEntries(recording),
    item("Quitar la copia de audio…", () => void removeAudio(recording), { enabled: Boolean(recording.audioPath) }),
    item("Borrar de la biblioteca…", () => void forget(recording)),
  ];

  const actionsMenu = (recording: Recording): MenuEntry[] => {
    const version = currentVersion(recording);
    const job = jobFor(recording);
    return [
      item("Copiar la transcripción", () => version && void perform(() => operations.copyTranscript(version.transcript)), { enabled: Boolean(version) }),
      item(version?.digest ? "Rehacer el resumen" : "Resumir con el modelo del sistema", () => void perform(() => operations.summarize(recording)), {
        enabled: canSummarize && Boolean(version) && !job,
      }),
      item("Quitar el resumen", () => void perform(() => operations.forgetSummary(recording)), { enabled: Boolean(version?.digest) }),
      item("Copiar el JSON", () => version && void perform(() => operations.copyJSON(recording, version)), { enabled: Boolean(version) }),
      submenu(
        "Exportar",
        operations.exportFormats.map((format) => item(format.label, () => version && void perform(() => operations.exportTranscript(format.id, recording, version)))),
        Boolean(version),
      ),
      separator,
      ...publishEntries(recording),
      item("Quitar la copia de audio…", () => void removeAudio(recording), { enabled: Boolean(recording.audioPath) }),
      ...(job ? [separator, item("Cancelar el proceso", () => void perform(() => operations.cancel(recording)))] : []),
      separator,
      item("Borrar de la biblioteca…", () => void forget(recording)),
    ];
  };

  const versionsMenu = (recording: Recording): MenuEntry[] => {
    const versions = versionsInOrder(recording);
    const current = currentVersion(recording);
    return [
      ...versions.map((version, index) =>
        item(versionTitle(version, index + 1, data.recipes, data.resolvers), () => version.id !== current?.id && void perform(() => operations.chooseVersion(recording, version)), {
          checked: version.id === current?.id,
        }),
      ),
      ...(versions.length ? [separator] : []),
      item("Reprocesar con una receta…", () => setReprocessing(recording), { enabled: Boolean(recording.audioPath) }),
    ];
  };

  const speakersMenu = (recording: Recording): MenuEntry[] => {
    const transcript = currentVersion(recording)?.transcript;
    const names = transcript ? speakers(transcript) : [];
    return [
      header("Hablantes"),
      ...names.map((speaker) =>
        submenu(speaker, [
          item("Renombrar…", () => setRename({ recording, speaker, name: speaker })),
          ...names
            .filter((other) => other !== speaker)
            .map((other) => item(`Fusionar con ${other}`, () => void perform(() => operations.mergeSpeaker(recording, speaker, other)))),
        ]),
      ),
    ];
  };

  const move = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const index = recordings.findIndex((recording) => recording.id === selectedId);
    const next = recordings[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), recordings.length - 1)];
    if (next) setSelectedId(next.id);
  };
  const contextMenu = (event: MouseEvent, recording: Recording) => {
    event.preventDefault();
    setSelectedId(recording.id);
    void popupMenu(rowMenu(recording), { x: event.clientX, y: event.clientY });
  };

  const selectedJob = selected ? jobFor(selected) : undefined;
  const selectedSpeakers = detail ? speakers(currentVersion(detail)?.transcript ?? { text: "", segments: [] }) : [];
  const toolbar = (
    <>
      {selected && (
        <>
          {selectedJob && <Spinner />}
          <ToolbarMenu icon={History} label={currentVersionLabel(selected)} showsTitle menu={() => versionsMenu(selected)} disabled={Boolean(selectedJob)} />
          <ToolbarMenu icon={Users} label="Hablantes" menu={() => (detail ? speakersMenu(detail) : [])} disabled={!selectedSpeakers.length || Boolean(selectedJob)} />
          <ToolbarMenu icon={Ellipsis} label="Acciones" menu={() => actionsMenu(detail ?? selected)} />
        </>
      )}
      <ToolbarMenu
        icon={FolderPlus}
        label="Añadir audio…"
        help="Añadir audios con la receta por defecto; en la flecha, con otra"
        primary={() => void chooseAudio()}
        menu={() => recipeChoices((recipeId) => void chooseAudio(recipeId))}
      />
      {isRecording ? (
        <ToolbarButton icon={CircleStop} label="Detener" help="Detener y transcribir" onClick={() => void stop()} tint="var(--red)" />
      ) : (
        <ToolbarMenu
          icon={Mic}
          label="Grabar"
          help="Grabar una nota de voz con la receta por defecto; en la flecha, con otra"
          primary={() => void record()}
          menu={() => recipeChoices((recipeId) => void record(recipeId))}
        />
      )}
    </>
  );

  return (
    <Pane title={selected ? displayTitle(selected) : "Biblioteca"} toolbar={toolbar}>
      <div className="list-detail">
        <div className="recording-list" role="listbox" aria-label="Grabaciones" tabIndex={0} onKeyDown={move}>
          {recordings.map((recording) => (
            <div
              key={recording.id}
              role="option"
              aria-selected={recording.id === selectedId}
              className={`list-row ${recording.id === selectedId ? "selected" : ""}`}
              onMouseDown={() => setSelectedId(recording.id)}
              onContextMenu={(event) => contextMenu(event, recording)}
            >
              <RecordingRow recording={recording} origin={originName(recording, folders)} minute={minute} destinations={data.destinations} accounts={data.accounts} />
            </div>
          ))}
        </div>
        <div className="list-detail-divider" />
        <div className="detail-column">
          {selected ? (
            <TranscriptDetail
              key={selected.id}
              recording={detail ?? selected}
              loading={!detail}
              origin={originName(selected, folders)}
              job={selectedJob}
              recipes={data.recipes}
              canSummarize={canSummarize}
              onReprocess={() => void perform(() => operations.reprocess(selected))}
              onSummarize={() => void perform(() => operations.summarize(selected))}
            />
          ) : (
            <ContentUnavailable
              title="Elige una grabación"
              icon={AudioLines}
              description={`${librarySummary(recordings.map((recording) => recording.status))}\nArrastra aquí un audio o pulsa Grabar.`}
            />
          )}
        </div>
      </div>
      {notice && (
        <div className="notice-bar font-callout">
          <span>{notice}</span>
          <button type="button" className="notice-close" onClick={() => setNotice(null)} aria-label="Cerrar aviso">
            <X size={13} />
          </button>
        </div>
      )}
      {dropTargeted && (
        <div className="drop-hint">
          <div className="drop-hint-label font-title3">Suelta para transcribir</div>
        </div>
      )}
      {reprocessing && (
        <ReprocessSheet
          recording={reprocessing}
          data={data}
          onCancel={() => setReprocessing(null)}
          onRun={(recipeId) => {
            setReprocessing(null);
            void perform(() => operations.reprocess(reprocessing, recipeId));
          }}
        />
      )}
      {rename && (
        <Sheet onCancel={() => setRename(null)}>
          <div className="font-headline">Renombrar hablante</div>
          <TextField
            value={rename.name}
            autoFocus
            onChange={(name) => setRename({ ...rename, name })}
            onSubmit={() => {
              const target = rename;
              setRename(null);
              void perform(() => operations.renameSpeaker(target.recording, target.speaker, target.name));
            }}
            placeholder="Nombre"
          />
          <div className="sheet-actions">
            <Button onClick={() => setRename(null)}>Cancelar</Button>
            <Button
              prominent
              onClick={() => {
                const target = rename;
                setRename(null);
                void perform(() => operations.renameSpeaker(target.recording, target.speaker, target.name));
              }}
            >
              Renombrar
            </Button>
          </div>
        </Sheet>
      )}
    </Pane>
  );
}

function okfFile(destination: Destination, accounts: Account[], receipt: Record<string, unknown>) {
  if (destination.provider !== "okf") return null;
  const root = accounts.find((account) => account.id === destination.account)?.folder;
  const locator = typeof receipt.locator === "string" ? receipt.locator : "";
  if (!root || !locator) return null;
  const folder = typeof receipt.folder === "string" && receipt.folder ? `/${receipt.folder}` : "";
  return `${root}${folder}/${locator}`.replace(/\/+/g, "/");
}

function ReprocessSheet({ recording, data, onCancel, onRun }: { recording: Recording; data: Snapshot; onCancel: () => void; onRun: (recipeId?: string) => void }) {
  const [recipeId, setRecipeId] = useState(data.settings.defaultRecipeId);
  const options = data.recipes.map((recipe) => ({
    value: recipe.id,
    label: recipe.id === data.settings.defaultRecipeId ? `${recipe.name} (por defecto)` : recipe.name,
  }));
  return (
    <Sheet onCancel={onCancel}>
      <div className="font-headline">Reprocesar con una receta</div>
      <div>
        <div className="form-group">
          <div className="form-row">
            <span>Receta</span>
            <PopupButton label="Receta" value={recipeId} options={options} onChange={setRecipeId} />
          </div>
        </div>
        <div className="form-footer font-caption secondary">{`«${displayTitle(recording)}» se procesa con esta receta solo esta vez.`}</div>
      </div>
      <p className="font-caption secondary">
        La receta hace su recorrido entero. Si no cambian los criterios de transcripción, aprovecha la transcripción que ya hay; si cambian, sale una versión
        nueva y la anterior se conserva. Publica donde diga la receta y regenera las páginas que ya existían.
      </p>
      <div className="sheet-actions">
        <Button onClick={onCancel}>Cancelar</Button>
        <Button prominent onClick={() => onRun(recipeId === data.settings.defaultRecipeId ? undefined : recipeId)}>
          Reprocesar
        </Button>
      </div>
    </Sheet>
  );
}
