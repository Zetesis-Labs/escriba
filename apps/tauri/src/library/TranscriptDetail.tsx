import { AlertTriangle, Clock, Sparkles, VolumeX } from "lucide-react";
import { useEffect, useState } from "react";
import { audioURL, call, desktop } from "../api";
import { clockStamp, longDate, playbackPosition, speakers } from "../core/presentation";
import { Button, Spinner } from "../mac/controls";
import type { JobState, Recipe, RecipeTrace, Recording } from "../types";
import { Karaoke } from "./Karaoke";
import { currentVersion, transcriptDuration, versionsInOrder } from "./model";
import { NoteDataSection } from "./NoteDataView";
import { PlayerBar, usePlayer } from "./Player";
import { displayTitle, TagChips } from "./RecordingRow";
import { TraceCard } from "./TraceCard";

export function useLatestTrace(recording: Recording, revision: string) {
  const [trace, setTrace] = useState<RecipeTrace | null>(null);
  useEffect(() => {
    if (!desktop) return;
    let current = true;
    void call<RecipeTrace[]>("trace_list", { recordingId: recording.id })
      .then((traces) => {
        if (!current) return;
        const latest = traces.filter((item) => !item.dryRun).sort((a, b) => b.finishedAt.localeCompare(a.finishedAt))[0];
        setTrace(latest ?? null);
      })
      .catch(() => current && setTrace(null));
    return () => {
      current = false;
    };
  }, [recording.id, revision]);
  return trace;
}

export function TranscriptDetail({
  recording,
  origin,
  job,
  recipes,
  canSummarize,
  onReprocess,
  onSummarize,
}: {
  recording: Recording;
  origin: string;
  job?: JobState;
  recipes: Recipe[];
  canSummarize: boolean;
  onReprocess: () => void;
  onSummarize: () => void;
}) {
  const player = usePlayer(recording.audioPath ? audioURL(recording.audioPath) : null);
  const version = currentVersion(recording);
  const versions = versionsInOrder(recording);
  const trace = useLatestTrace(recording, `${recording.status}-${recording.versions.length}-${job?.stage ?? ""}`);
  const transcript = version?.transcript;
  const duration = transcriptDuration(transcript);
  const speakerCount = transcript ? speakers(transcript).length : 0;
  const recipeName = recipes.find((recipe) => recipe.id === trace?.recipeId)?.name;
  const details = [
    longDate(new Date(recording.createdAt)),
    origin,
    duration !== undefined ? clockStamp(duration) : null,
    speakerCount > 1 ? `${speakerCount} hablantes` : null,
    versions.length > 1 && version ? `versión ${versions.indexOf(version) + 1} de ${versions.length}` : null,
  ]
    .filter(Boolean)
    .join(" · ");
  const summarizing = job?.stage === "Resumiendo";

  return (
    <div className="transcript-detail">
      {recording.audioPath ? (
        <PlayerBar player={player} />
      ) : (
        <div className="audio-missing font-caption secondary">
          <VolumeX size={13} strokeWidth={1.8} /> Solo queda la transcripción: el audio ya no existe
        </div>
      )}
      <div className="detail-divider" />
      <div className="detail-scroll">
        <div className="detail-content">
          <header className="detail-header">
            <h1 className="font-title selectable">{displayTitle(recording)}</h1>
            <div className="font-callout secondary">{details}</div>
            {version?.digest?.tags?.length ? <TagChips tags={version.digest.tags} /> : null}
          </header>
          {transcript ? (
            <>
              {summarizing ? (
                <div className="inline-progress">
                  <Spinner /> <span className="secondary">Resumiendo…</span>
                </div>
              ) : version?.digest?.summary ? (
                <section className="detail-section">
                  <h2 className="font-headline">Resumen</h2>
                  <p className="selectable">{version.digest.summary}</p>
                </section>
              ) : canSummarize ? (
                <div>
                  <Button icon={Sparkles} onClick={onSummarize}>
                    Resumir
                  </Button>
                </div>
              ) : null}
              <NoteDataSection data={version?.data} schema={version?.dataSchema} />
              <section className="detail-section">
                <h2 className="font-headline">Transcripción</h2>
                <Karaoke transcript={transcript} position={playbackPosition(transcript, player.currentTime)} onSeek={(time) => player.seek(time, true)} />
              </section>
              {trace && <TraceCard trace={trace} recipeName={recipeName} />}
            </>
          ) : (
            <StatusPlaceholder recording={recording} job={job} onReprocess={onReprocess} trace={trace} recipeName={recipeName} />
          )}
        </div>
      </div>
    </div>
  );
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
