import { useEffect, useMemo, useSyncExternalStore } from "react";
import { call } from "../api";
import { alertMessage } from "../mac/native";
import type { NoteDraft, NoteDraftCommit, Recording } from "../types";
import { createNoteDraftSession, type NoteDraftHost } from "./noteDraftSession";

const tauriHost: NoteDraftHost = {
  get: (recordingId) => call<NoteDraft | null>("note_draft_get", { recordingId }),
  begin: (recordingId) => call<NoteDraft>("note_draft_begin", { recordingId }),
  save: (recordingId, draftId, expectedRevision, content) =>
    call<NoteDraft>("note_draft_save", { recordingId, draftId, expectedRevision, content }),
  discard: (recordingId, draftId, expectedRevision) =>
    call<null>("note_draft_discard", { recordingId, draftId, expectedRevision }),
  commit: (recordingId, draftId, expectedRevision) =>
    call<NoteDraftCommit>("note_draft_commit", { recordingId, draftId, expectedRevision }),
};

interface Entry {
  recording: Recording;
  session: ReturnType<typeof createNoteDraftSession>;
  subscribers: number;
  visible: boolean;
  loaded: boolean;
  releasing: boolean;
  alertedErrors: Set<string>;
  alertHiddenError: () => void;
  subscribe: (listener: () => void) => () => void;
}

const sessions = new Map<string, Entry>();
function entryFor(recording: Recording): Entry {
  const existing = sessions.get(recording.id);
  if (existing) {
    existing.recording = recording;
    return existing;
  }
  let entry: Entry;
  const session = createNoteDraftSession(recording.id, tauriHost);
  const alertHiddenError = () => {
    const state = session.getState();
    if (entry.visible || !state.draft || !state.error) return;
    const key = JSON.stringify([state.draft.id, state.draft.revision, state.error]);
    if (entry.alertedErrors.has(key)) return;
    entry.alertedErrors.add(key);
    const text = `El borrador de «${entry.recording.title}» tiene un error: ${state.error} Tus correcciones siguen abiertas. Vuelve a la nota para reintentar.`;
    void alertMessage("Borrador sin conservar", text).catch(() => {});
  };
  const release = () => {
    if (entry.subscribers > 0 || !entry.loaded || entry.releasing || session.getState().loading) return;
    entry.releasing = true;
    void session.flush()
      .then(() => {
        const state = session.getState();
        if (entry.subscribers === 0 && !state.loading && !state.saving && !state.busy && !state.error && !state.commitPending && sessions.get(recording.id) === entry)
          sessions.delete(recording.id);
      })
      .catch(() => {})
      .finally(() => { entry.releasing = false; });
  };
  entry = {
    recording,
    session,
    subscribers: 0,
    visible: true,
    loaded: false,
    releasing: false,
    alertedErrors: new Set(),
    alertHiddenError,
    subscribe: (listener) => {
      entry.subscribers++;
      const unsubscribe = session.subscribe(listener);
      return () => {
        unsubscribe();
        entry.subscribers--;
        release();
        if (entry.subscribers === 0) queueMicrotask(() => {
          if (entry.subscribers === 0) {
            entry.visible = false;
            alertHiddenError();
          }
        });
      };
    },
  };
  session.subscribe(release);
  session.subscribe(alertHiddenError);
  sessions.set(recording.id, entry);
  return entry;
}

export function useNoteDraft(recording: Recording, active = true) {
  const entry = useMemo(() => entryFor(recording), [recording.id]);
  entry.recording = recording;
  entry.visible = active;
  const state = useSyncExternalStore(entry.subscribe, entry.session.getState, entry.session.getState);
  useEffect(() => {
    if (!entry.loaded) {
      entry.loaded = true;
      void entry.session.load().catch(() => {});
    }
  }, [entry]);
  useEffect(() => {
    if (!active) entry.alertHiddenError();
  }, [entry, active]);
  return { state, session: entry.session };
}
