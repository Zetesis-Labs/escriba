import { AlertTriangle, Clock, FileText, ListTree, Pencil, Sparkles, Tag, VolumeX, Workflow } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { audioURL, call, desktop } from "../api";
import { currentDemoPeople } from "../app/demo";
import { clockStamp, longDate, playbackPosition, speakers } from "../core/presentation";
import { forgottenRecognition, personColors } from "../core/people";
import { assignSelectedSpeaker, changeSegmentText, renameSpeaker, transcriptWithSegments } from "../core/transcriptEditing";
import { transcriptGroups } from "../core/transcriptGroups";
import { Button, Sheet, Spinner } from "../mac/controls";
import { errorText } from "../mac/native";
import type { Digest, JobState, NoteContent, Person, Recipe, RecipeTrace, Recording } from "../types";
import { currentVersion, transcriptDuration, versionsInOrder } from "./model";
import { NoteDataView } from "./NoteDataView";
import { NoteDataEditor } from "./NoteDataEditor";
import { PlayerBar, usePlayer } from "./Player";
import { displayTitle, TagChips } from "./RecordingRow";
import { TraceCard } from "./TraceCard";
import { GrowingTextArea, SpeakerPicker, TranscriptEditor, type SpeakerTarget } from "./TranscriptEditor";
import { useNoteDraft } from "./useNoteDraft";
import { republish } from "./operations";
import "./noteDetail.css";
import { KnowledgeCard } from "../knowledge/KnowledgeCard";
import { demoKnowledgeHost } from "../knowledge/demo";

export type NoteEditRequest = { serial: number; kind: "speaker" | "forgetSpeaker" | "removeSummary"; speaker?: string };

export function useLatestTrace(recording: Recording, revision: string) {
  const [trace, setTrace] = useState<RecipeTrace | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!desktop) return;
    let current = true;
    setError(null);
    void call<RecipeTrace[]>("trace_list", { recordingId: recording.id })
      .then((traces) => {
        if (!current) return;
        const latest = traces.filter((item) => !item.dryRun).sort((a, b) => b.finishedAt.localeCompare(a.finishedAt))[0];
        setTrace(latest ?? null);
      })
      .catch((failure) => { if (current) { setTrace(null); setError(errorText(failure)); } });
    return () => { current = false; };
  }, [recording.id, revision]);
  return { trace, error };
}

export function TranscriptDetail({ recording, origin, job, recipes, canSummarize, loading, active, editRequest, onDraftState, onRefresh, onReprocess, onSummarize }: {
  recording: Recording; loading: boolean; active: boolean; origin: string; job?: JobState; recipes: Recipe[]; canSummarize: boolean;
  editRequest: NoteEditRequest | null; onDraftState(locked: boolean): void; onRefresh(): Promise<void>; onReprocess(): void; onSummarize(): void;
}) {
  const player = usePlayer(recording.audioPath ? audioURL(recording.audioPath) : null);
  const version = currentVersion(recording);
  const versions = versionsInOrder(recording);
  const { state, session } = useNoteDraft(recording, active);
  const form = useRef<HTMLFormElement>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [discarding, setDiscarding] = useState(false);
  const [recovering, setRecovering] = useState(false);
  const [publicationFailed, setPublicationFailed] = useState(false);
  const [picker, setPicker] = useState<{ target: SpeakerTarget; transcript: NoteContent["transcript"] } | null>(null);
  const [people, setPeople] = useState<Person[]>([]);
  const [peopleError, setPeopleError] = useState<string | null>(null);
  const [tagInput, setTagInput] = useState("");
  const handledRequest = useRef<number | null>(null);
  const { trace, error: traceError } = useLatestTrace(recording, `${recording.status}-${recording.versions.length}-${job?.stage ?? ""}`);
  const content = state.content;
  const sourceTranscript = content?.transcript ?? version?.transcript;
  const transcript = useMemo(() => sourceTranscript && transcriptWithSegments(sourceTranscript), [sourceTranscript]);
  const digest = content ? content.digest : version?.digest;
  const editing = !!state.draft;
  const disabled = loading || state.loading || state.busy || state.commitPending || state.conflict || !!job;
  const duration = transcriptDuration(transcript);
  const speakerNames = transcript ? speakers(transcript) : [];
  const speakerCount = speakerNames.length;
  const speakerColors = personColors(speakerNames, people);
  const turnCount = transcript ? transcriptGroups(transcript.segments).length : 0;
  const recipeName = recipes.find((recipe) => recipe.id === trace?.recipeId)?.name;
  const details = [longDate(new Date(recording.createdAt)), origin, duration !== undefined ? clockStamp(duration) : null,
    speakerCount > 0 ? `${speakerCount} ${speakerCount === 1 ? "hablante" : "hablantes"}` : null,
    version ? `versión ${versions.indexOf(version) + 1} de ${versions.length}` : null].filter(Boolean).join(" · ");
  const seek = useCallback((time: number) => player.seek(time, true), [player.seek]);

  useEffect(() => { onDraftState(editing || state.loading || state.busy || state.commitPending); }, [editing, state.loading, state.busy, state.commitPending, onDraftState]);
  useEffect(() => {
    if (!active) return;
    let current = true;
    setPeopleError(null);
    const request = desktop ? call<Person[]>("people_list") : Promise.resolve(currentDemoPeople());
    void request.then((result) => { if (current) setPeople(result); }).catch((error) => { if (current) setPeopleError(`No se pudieron cargar las personas: ${errorText(error)}`); });
    return () => { current = false; };
  }, [active, !!picker]);

  const run = async (operation: () => Promise<unknown>) => {
    setActionError(null);
    try { await operation(); } catch (error) { setActionError(errorText(error)); }
  };
  const update = (change: Partial<NoteContent>) => {
    const latest = session.getState().content;
    if (latest) session.update({ ...latest, ...change });
  };
  const updateDigest = (change: Partial<Digest>) => {
    const latest = session.getState().content;
    if (latest) update({ digest: { title: latest.title, summary: "", tags: [], ...latest.digest, ...change } });
  };
  const openPicker = (target: SpeakerTarget) => void run(async () => {
    await session.begin();
    const latest = session.getState().content;
    if (latest) setPicker({ target, transcript: latest.transcript });
  });
  useEffect(() => {
    if (!editRequest || handledRequest.current === editRequest.serial || loading) return;
    handledRequest.current = editRequest.serial;
    if (editRequest.kind === "speaker" && editRequest.speaker) openPicker({ kind: "speaker", speaker: editRequest.speaker });
    else void run(async () => {
      await session.begin();
      const latest = session.getState().content;
      if (!latest) return;
      if (editRequest.kind === "removeSummary") updateDigest({ summary: "" });
      else if (editRequest.speaker) {
        const corrected = forgottenRecognition(latest.transcript, editRequest.speaker);
        if (corrected) update({ transcript: corrected });
      }
    });
  }, [editRequest, loading]);
  const chooseSpeaker = (name: string) => {
    const latest = session.getState().content;
    if (!latest || !picker) return;
    if (latest.transcript !== picker.transcript) { setPicker(null); setActionError("La transcripción cambió. Vuelve a seleccionar el fragmento."); return; }
    const segmented = transcriptWithSegments(latest.transcript);
    const changed = picker.target.kind === "speaker" ? renameSpeaker(segmented, picker.target.speaker, name) : assignSelectedSpeaker(segmented, picker.target.ranges, name);
    update({ transcript: changed });
    setPicker(null);
  };
  const commit = () => void run(async () => {
    if (!form.current?.reportValidity()) return;
    if (tagInput.trim()) addTags();
    const result = await session.commit();
    await onRefresh();
    if (result.created && desktop) {
      try { await republish(recording); setPublicationFailed(false); }
      catch (error) { setPublicationFailed(true); throw error; }
    }
  });
  useEffect(() => {
    if (!active || !editing) return;
    const save = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") { event.preventDefault(); if (!state.busy) commit(); }
    };
    window.addEventListener("keydown", save);
    return () => window.removeEventListener("keydown", save);
  });
  const addTags = () => {
    const tags = tagInput.split(",").map((tag) => tag.trim()).filter(Boolean);
    if (tags.length) updateDigest({ tags: [...new Set([...(session.getState().content?.digest?.tags ?? []), ...tags])] });
    setTagInput("");
  };
  const error = actionError ?? state.error;
  const data = content ? content.data : version?.data;
  const graphDemo = useMemo(() => demoKnowledgeHost(recording.id), [recording.id]);

  return <div className="transcript-detail">
    {recording.audioPath ? <PlayerBar player={player} /> : <div className="audio-missing font-caption secondary"><VolumeX size={13} /> Solo queda la transcripción: el audio ya no existe</div>}
    <div className="note-edit-bar">
      <div className="draft-status font-caption" role="status">{editing ? <><span className="draft-dot" /><strong>Borrador</strong><span className="secondary">{state.busy ? "Guardando cambios…" : state.saving ? "Conservando borrador…" : state.error ? "No se pudo conservar" : "Conservado en este Mac"}</span></> : <span className="secondary">{loading || state.loading ? "Cargando nota…" : "Contenido de la nota"}</span>}</div>
      {editing ? <><Button small disabled={state.busy || state.commitPending} onClick={() => setDiscarding(true)}>Descartar</Button><Button small prominent disabled={state.busy || state.conflict || !!job} onClick={commit}>{state.commitPending ? "Reintentar guardado" : "Guardar cambios"}</Button></> : <Button small icon={Pencil} disabled={disabled || !version} onClick={() => void run(() => session.begin())}>Editar</Button>}
    </div>
    {error && <div className="draft-error font-callout" role="alert"><span>{error}</span>{editing && !state.commitPending && <Button small onClick={() => void run(() => session.flush())}>Reintentar</Button>}{editing && <Button small disabled={state.busy || state.saving} onClick={() => setRecovering(true)}>Recuperar guardado…</Button>}{!editing && <Button small onClick={() => void run(async () => { if (publicationFailed) { await republish(recording); setPublicationFailed(false); await onRefresh(); } else await session.load(); })}>Reintentar</Button>}</div>}
    <div className="detail-scroll">
      <form ref={form} className="detail-content note-content" onSubmit={(event) => event.preventDefault()}>
        <header className="detail-header">
          {editing && content ? <GrowingTextArea className="note-title-input font-title" aria-label="Título" required value={content.title} disabled={disabled} onChange={(event) => { const title = event.target.value; update({ title, ...(content.digest ? { digest: { ...content.digest, title } } : {}) }); }} /> : <h1 className="font-title selectable">{displayTitle(recording)}</h1>}
          <div className="font-caption secondary note-metadata">{details}</div>
          {editing ? <label className="note-field-label">Descripción<GrowingTextArea className="note-description-input" aria-label="Descripción" placeholder="Una descripción breve de la nota" value={digest?.description ?? ""} disabled={disabled} onChange={(event) => updateDigest({ description: event.target.value })} /></label> : digest?.description ? <p className="note-description selectable">{digest.description}</p> : null}
          {editing ? <div className="note-tags"><div className="note-field-label"><Tag size={12} /> Etiquetas</div><div className="tag-chips">{digest?.tags.map((tag) => <span className="tag-chip editable-tag" key={tag}>{tag}<button type="button" disabled={disabled} aria-label={`Quitar etiqueta ${tag}`} onClick={() => updateDigest({ tags: digest.tags.filter((candidate) => candidate !== tag) })}>×</button></span>)}<input className="tag-input" aria-label="Añadir etiqueta" placeholder="Añadir etiqueta…" disabled={disabled} value={tagInput} onChange={(event) => setTagInput(event.target.value)} onBlur={addTags} onKeyDown={(event) => { if (event.key === "Enter" || event.key === ",") { event.preventDefault(); addTags(); } }} /></div></div> : digest?.tags?.length ? <TagChips tags={digest.tags} /> : null}
        </header>
        {loading ? <Spinner /> : transcript ? <>
          <section className="detail-section note-summary"><h2 className="note-section-title"><Sparkles size={15} />Resumen</h2>
            {job?.stage === "Resumiendo" ? <div className="inline-progress"><Spinner /><span className="secondary">Resumiendo…</span></div> : editing ? <GrowingTextArea className="note-summary-input" aria-label="Resumen" placeholder="Escribe el resumen…" disabled={disabled} value={digest?.summary ?? ""} onChange={(event) => updateDigest({ summary: event.target.value })} /> : digest?.summary ? <p className="selectable note-prose">{digest.summary}</p> : <div className="note-empty secondary"><span>Esta nota aún no tiene resumen.</span>{canSummarize && <Button small icon={Sparkles} onClick={onSummarize} disabled={!!job}>Resumir</Button>}</div>}
          </section>
          {(editing || data !== undefined && data !== null) && <section className="detail-section note-data-section"><h2 className="note-section-title"><ListTree size={15} />Datos de la receta</h2>{editing ? <NoteDataEditor value={data ?? null} schema={version?.dataSchema} disabled={disabled} onChange={(value) => update({ data: value })} /> : <NoteDataView data={data} schema={version?.dataSchema} />}</section>}
          <section className="detail-section note-transcription">{peopleError && <p className="warning font-caption" role="alert">{peopleError}</p>}<h2 className="note-section-title"><FileText size={15} />Transcripción<span className="secondary font-caption">{turnCount} {turnCount === 1 ? "intervención" : "intervenciones"}</span></h2>
            <TranscriptEditor transcript={transcript} editing={editing} disabled={disabled} position={playbackPosition(transcript, player.currentTime)} onSeek={seek} onText={(index, text) => update({ transcript: changeSegmentText(transcript, index, text) })} onAssign={openPicker} onError={setActionError} speakerColors={speakerColors} />
          </section>
          {traceError && <p className="warning font-callout" role="alert">No se pudo cargar la ejecución: {traceError}</p>}
          {version && active && !loading && !editing && !job && <KnowledgeCard key={`${recording.id}-${version.id}`} recordingId={recording.id} versionId={version.id} host={desktop ? undefined : graphDemo} />}
          {trace && <section className="detail-section"><h2 className="note-section-title"><Workflow size={15} />Cómo se procesó</h2><TraceCard trace={trace} recipeName={recipeName} /></section>}
        </> : <StatusPlaceholder recording={recording} job={job} onReprocess={onReprocess} trace={trace} recipeName={recipeName} />}
      </form>
    </div>
    {picker && <SpeakerPicker speakerColors={speakerColors} people={people} speakers={speakers(picker.transcript)} target={picker.target} excerpt={picker.target.kind === "selection" ? picker.target.ranges.map((range) => transcriptWithSegments(picker.transcript).segments[range.segment]?.text.slice(range.start, range.end) ?? "").join(" ") : ""} error={peopleError} onChoose={chooseSpeaker} onCancel={() => setPicker(null)} />}
    {recovering && <Sheet onCancel={() => setRecovering(false)}><div className="font-title3">¿Recuperar el borrador guardado?</div><p className="secondary">Se cargarán las últimas correcciones conservadas en este Mac. Los cambios que aún no se hayan podido guardar se perderán.</p><div className="sheet-actions"><Button onClick={() => setRecovering(false)}>Cancelar</Button><Button prominent onClick={() => { setRecovering(false); setTagInput(""); void run(() => session.load()); }}>Recuperar borrador</Button></div></Sheet>}
    {discarding && <Sheet onCancel={() => setDiscarding(false)}><div className="font-title3">¿Descartar este borrador?</div><p className="secondary">Se quitarán sus correcciones. La versión guardada se conserva.</p><div className="sheet-actions"><Button onClick={() => setDiscarding(false)}>Cancelar</Button><Button prominent onClick={() => { setDiscarding(false); setTagInput(""); void run(() => session.discard()); }}>Descartar borrador</Button></div></Sheet>}
  </div>;
}

function StatusPlaceholder({
  recording,
  job,
  onReprocess,
  trace,
  recipeName,
}: {
  recording: Recording;
  job?: JobState;
  onReprocess: () => void;
  trace: RecipeTrace | null;
  recipeName?: string;
}) {
  if (job || recording.status === "processing")
    return (
      <div className="inline-progress">
        <Spinner /> <span className="secondary">{job?.stage === "En cola" ? "En cola…" : `${job?.stage ?? "Transcribiendo"}…`}</span>
      </div>
    );
  if (recording.status === "pending")
    return (
      <div className="placeholder">
        <div className="placeholder-label">
          <Clock size={14} strokeWidth={1.8} /> En cola
        </div>
        <p className="secondary">Se transcribirá automáticamente en la próxima pasada.</p>
        <div>
          <Button onClick={onReprocess} disabled={!recording.audioPath}>
            Transcribir ahora
          </Button>
        </div>
      </div>
    );
  if (recording.status === "failed")
    return (
      <div className="placeholder">
        <div className="placeholder-label warning">
          <AlertTriangle size={14} strokeWidth={1.8} /> Falló la transcripción
        </div>
        {recording.error && <p className="font-caption secondary selectable">{recording.error}</p>}
        <div>
          <Button onClick={onReprocess} disabled={!recording.audioPath}>
            Reintentar
          </Button>
        </div>
        {trace && <TraceCard trace={trace} recipeName={recipeName} />}
      </div>
    );
  return <p className="secondary">Sin transcripción</p>;
}
