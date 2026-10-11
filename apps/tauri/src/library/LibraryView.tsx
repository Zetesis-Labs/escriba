import { getCurrentWebview } from "@tauri-apps/api/webview";
import { AlertTriangle, AudioLines, CircleStop, Ellipsis, FolderPlus, History, Mic, Users, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useState, type KeyboardEvent, type MouseEvent } from "react";
import { call, desktop, native, recordingDetail } from "../api";
import { Pane } from "../app/Pane";
import { audioExtensions, fileName, importNotice, importPlan } from "../core/inbox";
import { librarySummary, rowActionText, speakers } from "../core/presentation";
import { speakerTitle } from "../core/people";
import { reprocessChoice, reprocessDraft, reprocessTransition } from "../core/reprocessSheet";
import { recipeFormLoad } from "../core/recipeForm";
import { okfPublicationFile } from "../core/publicationFiles";
import { recordingRevision } from "../core/recordingDetail";
import { Button, ContentUnavailable, FormRow, FormSection, LabeledRow, PopupButton, Sheet, Spinner, ToolbarButton, ToolbarMenu } from "../mac/controls";
import { alertMessage, chooseFiles, confirmDestructive, errorText, header, item, popupMenu, separator, submenu, type MenuEntry } from "../mac/native";
import type { Destination, JobState, JSONObject, Recording, Snapshot } from "../types";
import { currentVersion, currentVersionLabel, isPublished, libraryRecordings, liveDestinations, originName, providerLabel, versionsInOrder, versionTitle } from "./model";
import * as operations from "./operations";
import { displayTitle, RecordingRow } from "./RecordingRow";
import { TranscriptDetail, type NoteEditRequest } from "./TranscriptDetail";
import { startRecording, stopRecording } from "../recording/useRecording";
import { getRecipeSchema } from "../runtime";
import { RecipeFormSections } from "../recipes/RecipeFormSections";
import "./library.css";


function useRecordingDetail(recording: Recording | null, active: boolean) {
  const [loaded, setLoaded] = useState<{ key: string; detail: Recording | null; error: string | null } | null>(null);
  const id = recording?.id;
  const revision = recording ? recordingRevision(recording) : "";
  const key = `${id ?? ""}:${revision}`;
  useEffect(() => {
    if (!recording || !active) {
      setLoaded(null);
      return;
    }
    if (!desktop) {
      setLoaded({ key, detail: recording, error: null });
      return;
    }
    let current = true;
    setLoaded(null);
    void recordingDetail(recording.id)
      .then((full) => {
        if (current) setLoaded({ key, detail: full, error: null });
      })
      .catch((failure) => {
        if (current) setLoaded({ key, detail: null, error: errorText(failure) });
      });
    return () => {
      current = false;
    };
  }, [id, revision, active]);
  const current = active && loaded?.key === key ? loaded : null;
  return { detail: current?.detail?.id === id ? current?.detail : null, detailError: current?.error ?? null };
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
  const [editRequest, setEditRequest] = useState<NoteEditRequest | null>(null);
  const [draftState, setDraftState] = useState<{ id: string; locked: boolean } | null>(null);
  const draftLocked = draftState?.id !== selectedId || draftState.locked;
  const onDraftState = useCallback((locked: boolean) => { if (selectedId) setDraftState({ id: selectedId, locked }); }, [selectedId]);
  const requestEdit = (kind: NoteEditRequest["kind"], speaker?: string) => setEditRequest((previous) => ({ serial: (previous?.serial ?? 0) + 1, kind, speaker }));
  const selected = recordings.find((recording) => recording.id === selectedId) ?? null;
  const { detail, detailError } = useRecordingDetail(selected, active);
  const live = liveDestinations(data.destinations, data.accounts, data.providers);
  const folders = data.settings.watchedFolders;
  const canSummarize = data.native?.llm?.available !== false;
  const minute = useMemo(() => Math.floor(Date.now() / 60_000), [data]);
  const jobFor = (recording: Recording) => jobs.find((job) => job.recordingId === recording.id);

  useEffect(() => {
    if (!active) {
      setReprocessing(null);
    }
  }, [active]);

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
      const accountId = publication.accountId ?? destination.account;
      const folder = data.accounts.find((account) => account.id === accountId)?.folder;
      const file = destination.provider === "okf" ? okfPublicationFile(folder, publication.receipt) : null;
      return submenu(destination.name, [
        ...(destination.provider === "notion" && url ? [item(`Abrir en ${kind}`, () => void perform(() => operations.openURL(url)))] : []),
        ...(file ? [
          item("Abrir el .md", () => void perform(() => operations.okfFile(accountId, file, "open"))),
          item("Mostrar en Finder", () => void perform(() => operations.okfFile(accountId, file, "reveal"))),
        ] : []),
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
      item(version?.digest?.summary ? "Rehacer el resumen" : "Resumir con el modelo del sistema", () => void perform(() => operations.summarize(recording)), {
        enabled: canSummarize && Boolean(version) && !job && !draftLocked,
      }),
      item("Quitar el resumen", () => requestEdit("removeSummary"), { enabled: Boolean(version?.digest?.summary) && !job }),
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
      header("Cambiar en toda la nota"),
      ...names.map((speaker) => submenu(transcript ? speakerTitle(speaker, transcript) : speaker, [
        item("Asignar a una persona…", () => requestEdit("speaker", speaker)),
        ...(transcript?.recognitions?.some((recognition) => recognition.person === speaker)
          ? [item(`No es ${speaker}`, () => requestEdit("forgetSpeaker", speaker))] : []),
      ])),
    ];
  };

  const move = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const index = recordings.findIndex((recording) => recording.id === selectedId);
    const next = recordings[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), recordings.length - 1)];
    if (next) { setEditRequest(null); setSelectedId(next.id); }
  };
  const contextMenu = (event: MouseEvent, recording: Recording) => {
    event.preventDefault();
    setEditRequest(null);
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
          <ToolbarMenu icon={History} label={currentVersionLabel(selected)} showsTitle menu={() => (detail ? versionsMenu(detail) : [])} disabled={!detail || Boolean(selectedJob) || draftLocked} />
          <ToolbarMenu icon={Users} label="Hablantes" menu={() => (detail ? speakersMenu(detail) : [])} disabled={!selectedSpeakers.length || Boolean(selectedJob)} />
          <ToolbarMenu icon={Ellipsis} label="Acciones" menu={() => (detail ? actionsMenu(detail) : [])} disabled={!detail} />
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
              onMouseDown={() => { setEditRequest(null); setSelectedId(recording.id); }}
              onContextMenu={(event) => contextMenu(event, recording)}
            >
              <RecordingRow recording={recording} origin={originName(recording, folders)} minute={minute} destinations={data.destinations} accounts={data.accounts} />
            </div>
          ))}
        </div>
        <div className="list-detail-divider" />
        <div className="detail-column">
          {selected && detailError ? (
            <ContentUnavailable title="No se pudo abrir la grabación" icon={AlertTriangle} description={detailError} />
          ) : selected ? (
            <TranscriptDetail
              key={selected.id}
              recording={detail ?? selected}
              loading={!detail}
              active={active}
              editRequest={editRequest}
              onDraftState={onDraftState}
              onRefresh={refresh}
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
          data={data}
          onCancel={() => setReprocessing(null)}
          onRun={(recipeId, values) => {
            setReprocessing(null);
            void perform(() => operations.reprocess(reprocessing, recipeId, values));
          }}
        />
      )}

    </Pane>
  );
}

function ReprocessSheet({ data, onCancel, onRun }: { data: Snapshot; onCancel: () => void; onRun: (recipeId: string, values?: JSONObject) => void }) {
  const [draft, setDraft] = useState(() => reprocessDraft(data.settings.defaultRecipeId));
  useEffect(() => {
    let current = true;
    const recipe = data.recipes.find((candidate) => candidate.id === draft.recipeId);
    const loaded = (load: ReturnType<typeof recipeFormLoad>) => {
      if (current) setDraft((previous) => reprocessTransition(previous, { type: "loaded", recipeId: draft.recipeId, load, saved: recipe?.values ?? {} }));
    };
    if (!desktop) loaded(recipeFormLoad(recipe?.schema ?? null));
    else void getRecipeSchema(draft.recipeId)
      .then((schema) => loaded(recipeFormLoad(schema)))
      .catch((failure) => loaded({ kind: "problem", problem: errorText(failure) }));
    return () => { current = false; };
  }, [draft.recipeId]);
  const options = data.recipes.map((recipe) => ({
    value: recipe.id,
    label: recipe.id === data.settings.defaultRecipeId ? `${recipe.name} (por defecto)` : recipe.name,
  }));
  const footer = draft.load === null
    ? "Leyendo sus parámetros…"
    : draft.load.kind === "noForm"
      ? "No tiene parámetros: hace lo que diga su código."
      : draft.load.kind === "form"
        ? "Los cambios de abajo valen solo para esta vez; la receta no cambia."
        : "Sus parámetros no se pueden pintar: se usan los guardados.";
  const run = () => {
    const choice = reprocessChoice(draft);
    onRun(choice.recipeId, choice.values);
  };
  return (
    <Sheet onCancel={onCancel}>
      <div className="font-headline">Reprocesar con una receta</div>
      <div className="reprocess-form" onKeyDown={(event) => {
        if (event.key === "Enter" && event.target instanceof HTMLInputElement) {
          event.preventDefault();
          run();
        }
      }}>
        <FormSection footer={footer}>
          <LabeledRow label="Receta">
            <PopupButton label="Receta" value={draft.recipeId} options={options} onChange={(recipeId) => setDraft((previous) => reprocessTransition(previous, { type: "select", recipeId }))} />
          </LabeledRow>
        </FormSection>
        {draft.load?.kind === "form" && <RecipeFormSections form={draft.load.form} values={draft.values} onChange={(values) => setDraft((previous) => reprocessTransition(previous, { type: "change", values }))} />}
        {draft.load?.kind === "problem" && (
          <FormSection header="Parámetros">
            <FormRow><span className="warning selectable">{draft.load.problem}</span></FormRow>
          </FormSection>
        )}
      </div>
      <p className="font-caption secondary">
        La receta hace su recorrido entero. Si no cambian los criterios de transcripción, aprovecha la transcripción que ya hay; si cambian, sale una versión
        nueva y la anterior se conserva. Publica donde diga la receta y regenera las páginas que ya existían.
      </p>
      <div className="sheet-actions">
        <Button onClick={onCancel}>Cancelar</Button>
        <Button prominent onClick={run}>
          Reprocesar
        </Button>
      </div>
    </Sheet>
  );
}
