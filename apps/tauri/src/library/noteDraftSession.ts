import type { NoteContent, NoteDraft, NoteDraftCommit } from "../types";

export interface NoteDraftHost {
  get(recordingId: string): Promise<NoteDraft | null>;
  begin(recordingId: string): Promise<NoteDraft>;
  save(recordingId: string, draftId: string, expectedRevision: number, content: NoteContent): Promise<NoteDraft>;
  discard(recordingId: string, draftId: string, expectedRevision: number): Promise<null>;
  commit(recordingId: string, draftId: string, expectedRevision: number): Promise<NoteDraftCommit>;
}

export interface NoteDraftState {
  draft: NoteDraft | null;
  content: NoteContent | null;
  loading: boolean;
  saving: boolean;
  busy: boolean;
  error: string | null;
  commitPending: boolean;
  conflict: boolean;
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);
const canonicalJSON = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(canonicalJSON);
  if (value !== null && typeof value === "object")
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, canonicalJSON(child)]));
  return value;
};

export function createNoteDraftSession(recordingId: string, host: NoteDraftHost) {
  let state: NoteDraftState = {
    draft: null,
    content: null,
    loading: false,
    saving: false,
    busy: false,
    error: null,
    commitPending: false,
    conflict: false,
  };
  const listeners = new Set<() => void>();
  let editRevision = 0;
  let savedRevision = 0;
  let write: Promise<void> | null = null;
  let loading: Promise<NoteDraft | null> | null = null;
  let beginning: Promise<NoteDraft> | null = null;
  let confirming: Promise<NoteDraftCommit> | null = null;
  let discarding: Promise<void> | null = null;

  const setState = (change: Partial<NoteDraftState>) => {
    state = { ...state, ...change };
    for (const listener of listeners) listener();
  };

  const saveQueue = () => {
    if (write) return write;
    if (state.conflict) return Promise.reject(Error(state.error ?? "El borrador cambió en otra ventana"));
    if (!state.draft || editRevision === savedRevision) return Promise.resolve();
    setState({ saving: true, error: null });
    const run = async () => {
      try {
        while (state.draft && editRevision !== savedRevision) {
          const draft = state.draft;
          const content = state.content;
          if (!content) throw Error("El borrador no tiene contenido");
          const revision = editRevision;
          let stored: NoteDraft;
          try {
            stored = await host.save(recordingId, draft.id, draft.revision, content);
          } catch (error) {
            let persisted: NoteDraft | null | undefined;
            try {
              persisted = await host.get(recordingId);
            } catch {}
            if (persisted?.id === draft.id && persisted.revision === draft.revision + 1
              && JSON.stringify(canonicalJSON(persisted.content)) === JSON.stringify(canonicalJSON(content))) {
              stored = persisted;
            } else if (persisted === null || persisted && (persisted.id !== draft.id || persisted.revision !== draft.revision)) {
              setState({ conflict: true });
              throw Error("El borrador cambió en otra ventana. Vuelve a cargarlo antes de guardar.");
            } else {
              throw error;
            }
          }
          savedRevision = revision;
          setState({ draft: stored });
        }
        setState({ saving: false });
      } catch (error) {
        setState({ saving: false, error: message(error) });
        throw error;
      }
    };
    write = run().finally(() => { write = null; });
    return write;
  };

  const flush = async () => {
    while (write || editRevision !== savedRevision) await saveQueue();
  };

  const load = () => {
    if (loading) return loading;
    setState({ loading: true, error: null });
    const run = host.get(recordingId)
      .then((draft) => {
        editRevision = 0;
        savedRevision = 0;
        setState({ draft, content: draft?.content ?? null, loading: false, saving: false, commitPending: false, conflict: false });
        return draft;
      })
      .catch((error: unknown) => {
        setState({ loading: false, error: message(error) });
        throw error;
      })
      .finally(() => { loading = null; });
    loading = run;
    return run;
  };

  const begin = () => {
    if (state.draft) return Promise.resolve(state.draft);
    if (beginning) return beginning;
    setState({ busy: true, error: null });
    const run = (async () => {
      try {
        const recovered = loading ? await loading : null;
        if (recovered) {
          setState({ busy: false });
          return recovered;
        }
        const draft = await host.begin(recordingId);
        editRevision = 0;
        savedRevision = 0;
        setState({ draft, content: draft.content, busy: false, conflict: false });
        return draft;
      } catch (error) {
        setState({ busy: false, error: message(error) });
        throw error;
      }
    })().finally(() => { beginning = null; });
    beginning = run;
    return run;
  };

  const update = (content: NoteContent) => {
    if (!state.draft || state.busy || state.commitPending || state.conflict) throw Error("El borrador no se puede editar ahora");
    editRevision++;
    setState({ content, saving: true, error: null });
    void saveQueue().catch(() => {});
  };

  const commit = () => {
    if (confirming) return confirming;
    if (!state.draft || state.busy) return Promise.reject(Error("No hay un borrador disponible para confirmar"));
    setState({ busy: true, error: null });
    const run = (async () => {
      try {
        if (!state.commitPending) await flush();
        const draft = state.draft;
        if (!draft) throw Error("El borrador ya no existe");
        setState({ commitPending: true });
        let result: NoteDraftCommit;
        try {
          result = await host.commit(recordingId, draft.id, draft.revision);
        } catch (error) {
          let persisted: NoteDraft | null | undefined;
          try {
            persisted = await host.get(recordingId);
          } catch {}
          if (persisted?.id === draft.id && persisted.revision === draft.revision)
            setState({ commitPending: false });
          else if (persisted?.id === draft.id) {
            setState({ commitPending: false, conflict: true });
            throw Error("El borrador cambió en otra ventana. Vuelve a cargarlo antes de guardar.");
          }
          throw error;
        }
        editRevision = 0;
        savedRevision = 0;
        setState({ draft: null, content: null, busy: false, commitPending: false, conflict: false });
        return result;
      } catch (error) {
        setState({ busy: false, error: message(error) });
        throw error;
      }
    })().finally(() => { confirming = null; });
    confirming = run;
    return run;
  };

  const discard = () => {
    if (discarding) return discarding;
    if (!state.draft || state.busy) return Promise.reject(Error("No hay un borrador disponible para descartar"));
    setState({ busy: true, error: null });
    const run = (async () => {
      try {
        if (write) await write.catch(() => {});
        const draft = state.draft;
        if (!draft) throw Error("El borrador ya no existe");
        await host.discard(recordingId, draft.id, draft.revision);
        editRevision = 0;
        savedRevision = 0;
        setState({ draft: null, content: null, saving: false, busy: false, commitPending: false, conflict: false });
      } catch (error) {
        setState({ busy: false, error: message(error) });
        throw error;
      }
    })().finally(() => { discarding = null; });
    discarding = run;
    return run;
  };

  return {
    getState: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => { listeners.delete(listener); };
    },
    load,
    begin,
    update,
    flush,
    commit,
    discard,
  };
}
