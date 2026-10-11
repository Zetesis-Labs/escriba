import { expect, test } from "vitest";
import { createNoteDraftSession, type NoteDraftHost, type NoteDraftState } from "../../src/library/noteDraftSession";
import type { NoteContent, NoteDraft, NoteDraftCommit } from "../../src/types";

const content = (title: string): NoteContent => ({
  title,
  transcript: { text: "Texto sintético", segments: [] },
  digest: null,
  data: null,
});
const draft = (revision = 0, title = "Original"): NoteDraft => ({
  id: "d1",
  recordingId: "r1",
  baseVersionId: "v1",
  baseFingerprint: "f1",
  revision,
  createdAt: "2026-10-11T10:00:00Z",
  updatedAt: "2026-10-11T10:00:00Z",
  content: content(title),
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function host(overrides: Partial<NoteDraftHost> = {}): NoteDraftHost {
  return {
    get: async () => draft(),
    begin: async () => draft(),
    save: async (_recordingId, _draftId, expectedRevision, proposed) => draft(expectedRevision + 1, proposed.title),
    discard: async () => null,
    commit: async () => ({ version: { id: "v2", createdAt: "2026-10-11T10:01:00Z", backend: "manual", transcript: content("Final").transcript }, created: true }),
    ...overrides,
  };
}

test("recupera el borrador y comenzar no abre otro", async () => {
  let begun = 0;
  const session = createNoteDraftSession("r1", host({ begin: async () => { begun++; return draft(); } }));
  const before = session.getState();
  expect(session.getState()).toBe(before);
  await session.load();
  expect(session.getState().draft?.id).toBe("d1");
  expect(session.getState().content?.title).toBe("Original");
  await session.begin();
  expect(begun).toBe(0);
});

test("la suscripción recibe estados nuevos y deja de avisar al cancelar", async () => {
  const session = createNoteDraftSession("r1", host());
  const snapshots: NoteDraftState[] = [];
  const unsubscribe = session.subscribe(() => { snapshots.push(session.getState()); });
  const initial = session.getState();
  await session.load();
  expect(session.getState()).not.toBe(initial);
  expect(snapshots.at(-1)).toBe(session.getState());
  const count = snapshots.length;
  unsubscribe();
  session.update(content("Cambio"));
  await session.flush();
  expect(snapshots).toHaveLength(count);
});

test("comenzar mientras carga reutiliza el borrador recuperado", async () => {
  const pending = deferred<NoteDraft | null>();
  let begun = 0;
  const session = createNoteDraftSession("r1", host({
    get: async () => pending.promise,
    begin: async () => { begun++; return draft(); },
  }));
  const loading = session.load();
  const beginning = session.begin();
  pending.resolve(draft());
  expect(await loading).toEqual(draft());
  expect(await beginning).toEqual(draft());
  expect(begun).toBe(0);
});

test("ediciones durante un guardado conservan el texto nuevo y serializan revisiones", async () => {
  const first = deferred<NoteDraft>();
  const calls: { revision: number; title: string }[] = [];
  const session = createNoteDraftSession("r1", host({
    save: async (_recordingId, _draftId, revision, proposed) => {
      calls.push({ revision, title: proposed.title });
      return calls.length === 1 ? first.promise : draft(revision + 1, proposed.title);
    },
  }));
  await session.load();
  session.update(content("Uno"));
  session.update(content("Dos"));
  expect(session.getState().content?.title).toBe("Dos");
  expect(calls).toEqual([{ revision: 0, title: "Uno" }]);
  first.resolve(draft(1, "Uno"));
  await session.flush();
  expect(calls).toEqual([{ revision: 0, title: "Uno" }, { revision: 1, title: "Dos" }]);
  expect(session.getState().content?.title).toBe("Dos");
  expect(session.getState().draft?.revision).toBe(2);
  expect(session.getState().saving).toBe(false);
});

test("confirmar espera el autoguardado y dos pulsaciones usan una sola confirmación", async () => {
  const saved = deferred<NoteDraft>();
  let commits = 0;
  const session = createNoteDraftSession("r1", host({
    save: async () => saved.promise,
    commit: async (_recordingId, _draftId, revision) => {
      expect(revision).toBe(1);
      commits++;
      return { version: { id: "v2", createdAt: "2026-10-11T10:01:00Z", backend: "manual", transcript: content("Final").transcript }, created: true };
    },
  }));
  await session.load();
  session.update(content("Final"));
  const a = session.commit();
  const b = session.commit();
  expect(a).toBe(b);
  expect(() => session.update(content("Tarde"))).toThrow();
  expect(commits).toBe(0);
  saved.resolve(draft(1, "Final"));
  const result = await a;
  expect(result.created).toBe(true);
  expect(commits).toBe(1);
  expect(session.getState().draft).toBeNull();
});

test("el fallo de guardado queda visible y se puede reintentar con la misma revisión", async () => {
  const revisions: number[] = [];
  let fail = true;
  const session = createNoteDraftSession("r1", host({
    save: async (_recordingId, _draftId, revision, proposed) => {
      revisions.push(revision);
      if (fail) throw Error("Sin conexión");
      return draft(revision + 1, proposed.title);
    },
  }));
  await session.load();
  session.update(content("Cambio"));
  await expect(session.flush()).rejects.toThrow("Sin conexión");
  expect(session.getState().content?.title).toBe("Cambio");
  expect(session.getState().error).toBe("Sin conexión");
  fail = false;
  await session.flush();
  expect(revisions).toEqual([0, 0]);
  expect(session.getState().error).toBeNull();
});

test("recupera una escritura aplicada aunque se pierda su respuesta", async () => {
  let persisted = draft();
  const proposed = { ...content("Cambio"), data: { z: { b: 2, a: 1 }, a: true } };
  const session = createNoteDraftSession("r1", host({
    get: async () => persisted,
    save: async (_recordingId, _draftId, revision, proposed) => {
      persisted = {
        ...draft(revision + 1, proposed.title),
        content: { data: { a: true, z: { a: 1, b: 2 } }, digest: proposed.digest, transcript: proposed.transcript, title: proposed.title },
      };
      throw Error("Respuesta perdida");
    },
  }));
  await session.load();
  session.update(proposed);
  await session.flush();
  expect(session.getState().draft?.revision).toBe(1);
  expect(session.getState().content?.title).toBe("Cambio");
  expect(session.getState().error).toBeNull();
});

test("una edición llegada mientras se comprueba la respuesta perdida sigue en la cola", async () => {
  const inspection = deferred<NoteDraft | null>();
  const calls: { revision: number; title: string }[] = [];
  let gets = 0;
  const session = createNoteDraftSession("r1", host({
    get: async () => ++gets === 1 ? draft() : inspection.promise,
    save: async (_recordingId, _draftId, revision, proposed) => {
      calls.push({ revision, title: proposed.title });
      if (calls.length === 1) throw Error("Respuesta perdida");
      return draft(revision + 1, proposed.title);
    },
  }));
  await session.load();
  session.update(content("Uno"));
  await Promise.resolve();
  session.update(content("Dos"));
  inspection.resolve(draft(1, "Uno"));
  await session.flush();
  expect(calls).toEqual([{ revision: 0, title: "Uno" }, { revision: 1, title: "Dos" }]);
  expect(session.getState().content?.title).toBe("Dos");
  expect(session.getState().draft?.revision).toBe(2);
});

test("una revisión ajena conserva el texto local y exige recarga explícita", async () => {
  let gets = 0;
  const session = createNoteDraftSession("r1", host({
    get: async () => ++gets === 1 ? draft() : draft(2, "Texto ajeno"),
    save: async () => { throw Error("Respuesta perdida"); },
  }));
  await session.load();
  session.update(content("Mi texto"));
  await expect(session.flush()).rejects.toThrow("El borrador cambió en otra ventana");
  expect(session.getState().conflict).toBe(true);
  expect(session.getState().content?.title).toBe("Mi texto");
  expect(() => session.update(content("Más"))).toThrow();
  await session.load();
  expect(session.getState().conflict).toBe(false);
  expect(session.getState().content?.title).toBe("Texto ajeno");
});

test("una confirmación ambigua conserva identificador y revisión para reintentar", async () => {
  const calls: [string, number][] = [];
  let fail = true;
  const receipt: NoteDraftCommit = { version: { id: "v2", createdAt: "2026-10-11T10:01:00Z", backend: "manual", transcript: content("Original").transcript }, created: true };
  const session = createNoteDraftSession("r1", host({
    get: async () => calls.length > 0 ? null : draft(),
    commit: async (_recordingId, id, revision) => {
      calls.push([id, revision]);
      if (fail) throw Error("Respuesta perdida");
      return receipt;
    },
  }));
  await session.load();
  await expect(session.commit()).rejects.toThrow("Respuesta perdida");
  expect(session.getState().commitPending).toBe(true);
  expect(session.getState().draft?.id).toBe("d1");
  expect(() => session.update(content("Otro"))).toThrow();
  fail = false;
  expect(await session.commit()).toBe(receipt);
  expect(calls).toEqual([["d1", 0], ["d1", 0]]);
});

test("un conflicto de versión base deja el borrador editable y descartable", async () => {
  let discarded = false;
  const session = createNoteDraftSession("r1", host({
    commit: async () => { throw Error("La versión de origen cambió"); },
    discard: async () => { discarded = true; return null; },
  }));
  await session.load();
  await expect(session.commit()).rejects.toThrow("La versión de origen cambió");
  expect(session.getState().commitPending).toBe(false);
  expect(session.getState().error).toBe("La versión de origen cambió");
  expect(session.getState().draft?.id).toBe("d1");
  await session.discard();
  expect(discarded).toBe(true);
});

test("si falla la inspección tras la confirmación mantiene pendiente y el error original", async () => {
  let gets = 0;
  const session = createNoteDraftSession("r1", host({
    get: async () => {
      gets++;
      if (gets === 1) return draft();
      throw Error("Sin conexión al comprobar");
    },
    commit: async () => { throw Error("Respuesta perdida"); },
  }));
  await session.load();
  await expect(session.commit()).rejects.toThrow("Respuesta perdida");
  expect(session.getState().commitPending).toBe(true);
  expect(session.getState().error).toBe("Respuesta perdida");
  expect(() => session.update(content("Otro"))).toThrow();
});

test("otro borrador recuperado no reemplaza el contenido local tras una respuesta perdida", async () => {
  let gets = 0;
  const session = createNoteDraftSession("r1", host({
    get: async () => ++gets === 1 ? draft() : { ...draft(), id: "d2" },
    commit: async () => { throw Error("Respuesta perdida"); },
  }));
  await session.load();
  await expect(session.commit()).rejects.toThrow("Respuesta perdida");
  expect(session.getState().draft?.id).toBe("d1");
  expect(session.getState().commitPending).toBe(true);
});

test("otra revisión del mismo borrador comunica conflicto sin perder el contenido local", async () => {
  let gets = 0;
  const session = createNoteDraftSession("r1", host({
    get: async () => ++gets === 1 ? draft() : draft(1, "Otro externo"),
    commit: async () => { throw Error("Respuesta perdida"); },
  }));
  await session.load();
  await expect(session.commit()).rejects.toThrow("El borrador cambió en otra ventana");
  expect(session.getState().draft?.revision).toBe(0);
  expect(session.getState().content?.title).toBe("Original");
  expect(session.getState().commitPending).toBe(false);
  expect(session.getState().conflict).toBe(true);
});

test("descartar tras conflicto espera una escritura y no exige que siga la versión base", async () => {
  const saving = deferred<NoteDraft>();
  let discarded = false;
  const session = createNoteDraftSession("r1", host({
    save: async () => saving.promise,
    discard: async (_recordingId, _draftId, revision) => {
      expect(revision).toBe(0);
      discarded = true;
      return null;
    },
  }));
  await session.load();
  session.update(content("Cambio"));
  const request = session.discard();
  expect(discarded).toBe(false);
  saving.reject(Error("La versión de origen cambió"));
  await request;
  expect(discarded).toBe(true);
  expect(session.getState().draft).toBeNull();
  expect(session.getState().content).toBeNull();
});
