import type { NoteContent, NoteDraft, NoteDraftCommit, Recording, Version } from "../types";
import type { NoteDraftHost } from "./noteDraftSession";

const drafts = new Map<string, NoteDraft>();
const receipts = new Map<string, { revision: number; recordingId: string; result: NoteDraftCommit }>();
const copy = <T>(value: T): T => structuredClone(value);
const fingerprint = (recording: Recording, version: Version) => JSON.stringify([recording.title, version]);
const latest = (recording: Recording) => {
  const version = recording.versions.find((item) => item.id === recording.currentVersionId);
  if (!version) throw Error("La nota no tiene una versión vigente");
  return version;
};
const versionContent = (recording: Recording, version: Version): NoteContent => ({
  title: version.digest?.title ?? version.title ?? recording.title,
  transcript: copy(version.transcript),
  digest: copy(version.digest ?? null),
  data: copy(version.data ?? null),
});

export function createDemoDraftHost(recording: () => Recording, publish: (recording: Recording) => void): NoteDraftHost {
  const current = (recordingId: string) => {
    const value = recording();
    if (value.id !== recordingId) throw Error("Grabación no encontrada");
    return value;
  };
  const pending = (recordingId: string, draftId: string, expectedRevision: number) => {
    const value = drafts.get(recordingId);
    if (!value || value.id !== draftId) throw Error("El borrador ya no existe");
    if (value.revision !== expectedRevision) throw Error("El borrador cambió en otra ventana. Vuelve a cargarlo antes de guardar.");
    return value;
  };
  const checkBase = (value: NoteDraft, source: Recording) => {
    const base = latest(source);
    if (value.baseVersionId !== base.id || value.baseFingerprint !== fingerprint(source, base))
      throw Error("La versión de origen cambió. El borrador se conserva; descártalo para editar la versión vigente.");
    return base;
  };
  return {
    async get(recordingId) {
      current(recordingId);
      return copy(drafts.get(recordingId) ?? null);
    },
    async begin(recordingId) {
      const source = current(recordingId);
      const existing = drafts.get(recordingId);
      if (existing) return copy(existing);
      const base = latest(source);
      const now = new Date().toISOString();
      const value: NoteDraft = {
        id: crypto.randomUUID(),
        recordingId,
        baseVersionId: base.id,
        baseFingerprint: fingerprint(source, base),
        revision: 0,
        createdAt: now,
        updatedAt: now,
        content: versionContent(source, base),
      };
      drafts.set(recordingId, value);
      return copy(value);
    },
    async save(recordingId, draftId, expectedRevision, content) {
      const source = current(recordingId);
      const value = pending(recordingId, draftId, expectedRevision);
      checkBase(value, source);
      const saved = { ...value, revision: value.revision + 1, updatedAt: new Date().toISOString(), content: copy(content) };
      drafts.set(recordingId, saved);
      return copy(saved);
    },
    async discard(recordingId, draftId, expectedRevision) {
      current(recordingId);
      pending(recordingId, draftId, expectedRevision);
      drafts.delete(recordingId);
      return null;
    },
    async commit(recordingId, draftId, expectedRevision) {
      const source = current(recordingId);
      const receipt = receipts.get(draftId);
      if (receipt) {
        if (receipt.recordingId !== recordingId || receipt.revision !== expectedRevision)
          throw Error("La confirmación del borrador no coincide");
        return copy(receipt.result);
      }
      const value = pending(recordingId, draftId, expectedRevision);
      const base = checkBase(value, source);
      const created = JSON.stringify(value.content) !== JSON.stringify(versionContent(source, base));
      const version: Version = created
        ? {
            ...copy(base),
            id: crypto.randomUUID(),
            createdAt: new Date().toISOString(),
            backend: "manual",
            title: value.content.title,
            transcript: copy(value.content.transcript),
            digest: copy(value.content.digest),
            data: copy(value.content.data),
          }
        : copy(base);
      const result = { version, created };
      const next = created
        ? { ...source, title: value.content.title, currentVersionId: version.id, versions: [...source.versions, version] }
        : source;
      drafts.delete(recordingId);
      receipts.set(draftId, { revision: expectedRevision, recordingId, result });
      if (created) publish(next);
      return copy(result);
    },
  };
}
