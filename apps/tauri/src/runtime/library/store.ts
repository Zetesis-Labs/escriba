import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { credentialPath } from "../credentials";
import { accessEquivalent, sameAuthority, validateAccountGrant } from "../http";
import { audioCopyRoot, audioCopyToDelete, fileHash, fileStem, importCreatedAt, linkStaged, referencesAudio, stageAudio, type StagedAudio } from "./audio";
import { changes, type RowOp } from "./changes";
import { conservativeVoices, currentVersion, draftContent, draftFingerprint, draftRequest, newDraft, parseDraftContent, readDraft, validateContent, type NoteDraft } from "./drafts";
import { array, canonical, clone, equal, isObject, newId, now, object, safeId, text, type Json } from "./json";
import { defaultResolvers, defaultWhisperModel, folderBookmarkRequired } from "../platform";
import { isLocalSttId, localSttId } from "../localModels";
import { catalog, readLibraryData, readRecording, readSettings, readVersion, setCatalog, type LibraryData, type Recording, type Settings, type Transcript, type Version, type WatchedFolder } from "./model";
import { Persistence, parseLogQuery, scope, scopedWrite, type AudioDeletion, type LibraryWrite, type Teaching, type WriteScope } from "./persistence";
import { lightPublication, previewVersion, typedLibrary } from "./projection";
import { recognize, validVoice, type KnownVoice, type SpeakerVoice } from "./voices";

export const SETTABLE = ["defaultRecipeId", "projectPath", "watchedFolders", "whisperModel", "launchAtLogin", "notifyEveryNote", "jobHistoryDays"];
const STYLES = ["any", "voiceMemos", "justPressRecord"];
const emptyLibrary = (): LibraryData => readLibraryData({ schemaVersion: 1, recordings: [], accounts: [], resolvers: [], recipes: [], destinations: [], providers: [], settings: {} });
export const defaults = (): Json => ({
  schemaVersion: 1,
  recordings: [],
  accounts: [],
  destinations: [],
  resolvers: defaultResolvers(),
  recipes: [{ id: "default", name: "Por defecto", kind: "form", values: {} }],
  settings: { defaultRecipeId: "default", projectPath: null, watchedFolders: [], language: "es", whisperModel: defaultWhisperModel(), launchAtLogin: false },
});
export function discardedRecord(record: Json): Record<string, Json> {
  return { id: text(record, "id"), source: field(record, "source"), sourceKey: field(record, "sourceKey"), legacyKey: field(record, "legacyKey"), status: "discarded" };
}
const field = (value: Json, key: string): Json => (isObject(value) && key in value ? (value[key] as Json) : null);
function migrateRecipeAssignments(data: Record<string, Json>) {
  const settings = data.settings as Record<string, Json>;
  if (settings.recipeSelectionMigrated === true) return;
  for (const record of array(data.recordings, "Biblioteca incompleta")) if (isObject(record) && record.status !== "discarded") record.recipeId = null;
  settings.recipeSelectionMigrated = true;
}
function importableLogs(lines: Json[]): Json[] {
  return lines
    .filter((line) => isObject(line) && typeof line.message === "string" && typeof line.at === "string")
    .map((line) => {
      const entry = { ...(line as Record<string, Json>) };
      if (typeof entry.id !== "string" || !entry.id) entry.id = newId();
      return entry;
    });
}
export function prune(value: Json, key: string): Json {
  if (Array.isArray(value)) return value.filter((item) => item !== key).map((item) => prune(item, key));
  if (isObject(value)) {
    const result: Record<string, Json> = {};
    for (const [name, item] of Object.entries(value)) if (item !== key) result[name] = prune(item as Json, key);
    return result;
  }
  return value;
}
export function stripEmbeddings(value: Json): Json {
  if (Array.isArray(value)) return value.map(stripEmbeddings);
  if (isObject(value)) {
    const result: Record<string, Json> = {};
    for (const [key, item] of Object.entries(value)) {
      const lower = key.toLowerCase();
      if (lower === "voices" || lower.includes("embedding")) continue;
      result[key] = stripEmbeddings(item as Json);
    }
    return result;
  }
  return value;
}
export function relabelVoices(source: Transcript, corrected: Transcript, voices: SpeakerVoice[]) {
  if (source.segments.length !== corrected.segments.length) throw Error("La corrección cambió los segmentos");
  const labels = new Map<string, string>();
  source.segments.forEach((before, index) => {
    const after = corrected.segments[index]!;
    if (typeof before.speaker === "string" && typeof after.speaker === "string") {
      const previous = labels.get(before.speaker);
      if (previous !== undefined && previous !== after.speaker) throw Error("Un hablante tiene nombres distintos en la corrección");
      labels.set(before.speaker, after.speaker);
    }
  });
  for (const voice of voices) {
    const label = labels.get(voice.speaker);
    if (label !== undefined) voice.speaker = label;
  }
}
export const canonicalFolder = (path: string): string => {
  let canonical: string;
  try {
    canonical = realpathSync(path);
  } catch (error) {
    throw Error(`No se puede acceder a la carpeta: ${(error as Error).message}`);
  }
  if (!statSync(canonical).isDirectory()) throw Error("La ruta elegida no es una carpeta");
  return canonical;
};
export function sameFolder(left: string, right: string): boolean {
  if (left === right) return true;
  try {
    return realpathSync(left) === realpathSync(right);
  } catch {
    return false;
  }
}
export function bookmarkBytes(value: Json): number[] {
  if (!Array.isArray(value) || !value.every((item) => typeof item === "number" && Number.isInteger(item) && item >= 0 && item <= 255))
    throw Error("La autorización guardada está dañada");
  if (!value.length) throw Error("La autorización guardada está vacía");
  return value as number[];
}
export function redactedFolder(folder: Json): Json {
  if (!isObject(folder)) return folder;
  const { accessBookmark, ...rest } = folder;
  let authorized = false;
  try {
    bookmarkBytes(accessBookmark as Json);
    authorized = true;
  } catch {
    authorized = false;
  }
  return { ...rest, authorizationSaved: authorized };
}
export function redactedSettings(settings: Json): Json {
  if (!isObject(settings)) return settings;
  const result = { ...settings };
  if (Array.isArray(result.watchedFolders)) result.watchedFolders = result.watchedFolders.map(redactedFolder);
  return result;
}
function sanitizeWatchedFolders(incoming: Json, existing: Json): Json[] {
  const items = array(incoming, "Carpetas inválidas");
  const previous = array(existing, "Carpetas inválidas");
  const seen = new Set<string>();
  return items.map((folder) => {
    const folderId = text(folder, "id");
    if (seen.has(folderId)) throw Error("Hay carpetas con el mismo identificador");
    seen.add(folderId);
    const path = text(folder, "path");
    const name = text(folder, "name");
    const style = typeof (folder as Record<string, Json>).style === "string" ? ((folder as Record<string, Json>).style as string) : "any";
    if (!STYLES.includes(style)) throw Error("Estilo de carpeta desconocido");
    const entry: Record<string, Json> = { id: folderId, path, name, style, enabled: (folder as Record<string, Json>).enabled !== false };
    const prior = previous.find((item) => isObject(item) && item.id === folderId) as Record<string, Json> | undefined;
    if (prior && sameFolder(path, text(prior, "path")) && prior.accessBookmark !== null && prior.accessBookmark !== undefined) entry.accessBookmark = prior.accessBookmark as Json;
    return entry;
  });
}
function updateSettings(settings: Settings, params: Json) {
  if (!isObject(params)) throw Error("Ajustes inválidos");
  const accepted: Record<string, Json> = {};
  for (const key of SETTABLE) if (key in params) accepted[key] = params[key] as Json;
  const update = readSettings(accepted);
  for (const key of ["defaultRecipeId", "projectPath", "whisperModel", "launchAtLogin", "notifyEveryNote"] as const)
    if (key in update) (settings as Record<string, unknown>)[key] = update[key];
  if ("jobHistoryDays" in update) {
    const days = update.jobHistoryDays;
    if (typeof days === "number" && ![7, 30, 90].includes(days)) throw Error("El historial de trabajos se guarda 7, 30 o 90 días, o siempre");
    settings.jobHistoryDays = days;
  }
  if ("watchedFolders" in update) {
    const sanitized = sanitizeWatchedFolders(update.watchedFolders as Json, (settings.watchedFolders ?? []) as Json);
    settings.watchedFolders = readSettings({ watchedFolders: sanitized }).watchedFolders;
  }
}
const foldersOf = (data: LibraryData): WatchedFolder[] => {
  const folders = data.settings.watchedFolders;
  if (!Array.isArray(folders)) throw Error("Carpetas inválidas");
  return folders;
};
type VersionCommit = [string, string, SpeakerVoice[], Teaching | undefined];
export interface StoreOptions {
  audioCleanup?: boolean;
}
export class Store {
  private pendingVoices = new Map<string, SpeakerVoice[]>();
  private constructor(
    readonly root: string,
    public data: LibraryData,
    readonly database: Persistence,
    private readonly audioCleanupEnabled: boolean,
  ) {}

  static async open(root: string, options: StoreOptions = {}): Promise<Store> {
    mkdirSync(root, { recursive: true });
    try {
      chmodSync(root, 0o700);
    } catch (error) {
      throw Error(`No se pudo proteger la biblioteca: ${(error as Error).message}`);
    }
    const database = await Persistence.open(join(root, "library.rocksdb"));
    try {
      return await Store.initialize(root, database, options.audioCleanup ?? true);
    } catch (error) {
      await database.close().catch(() => undefined);
      throw error;
    }
  }
  private static async initialize(root: string, database: Persistence, audioCleanupEnabled: boolean): Promise<Store> {
    chmodSync(join(root, "library.rocksdb"), 0o700);
    const stored = await database.loadIndex();
    const path = join(root, "library.json");
    let data: Record<string, Json>;
    if (stored !== undefined) data = clone(stored) as Record<string, Json>;
    else if (existsSync(path)) {
      try {
        data = JSON.parse(readFileSync(path, "utf8")) as Record<string, Json>;
      } catch (error) {
        throw Error(`No se puede leer la biblioteca: ${(error as Error).message}`);
      }
    } else data = defaults() as Record<string, Json>;
    if (!isObject(data) || data.schemaVersion !== 1) throw Error("Versión de biblioteca incompatible");
    if (data.providers === undefined) data.providers = [];
    const logs = data.logs;
    delete data.logs;
    const importedLogs = Array.isArray(logs) && stored === undefined ? importableLogs(logs) : [];
    migrateRecipeAssignments(data);
    const discardedAudio: string[] = [];
    const records = array(data.recordings, "Biblioteca incompleta");
    records.forEach((record, index) => {
      if (!isObject(record)) return;
      if (record.status === "discarded") {
        if (typeof record.audioPath === "string" && record.audioPath) discardedAudio.push(record.audioPath);
        records[index] = discardedRecord(record);
      } else if (record.status === "processing") {
        record.status = "pending";
        record.error = "El procesamiento se interrumpió al cerrar la app; se puede reanudar.";
      }
    });
    for (const dir of ["audio", "secrets", "captures", "packages"]) {
      const directory = join(root, dir);
      mkdirSync(directory, { recursive: true });
      try {
        chmodSync(directory, 0o700);
      } catch (error) {
        throw Error(`No se pudo proteger ${directory}: ${(error as Error).message}`);
      }
    }
    const typed = readLibraryData(data);
    const deletions = discardedAudio.map((audio) => audioCopyToDelete(root, typed, audio)).filter((deletion): deletion is AudioDeletion => deletion !== undefined);
    const storedIsNew = stored === undefined;
    const before = stored !== undefined ? readLibraryData(stored) : emptyLibrary();
    const ops = changes(before, typed, storedIsNew ? "all" : new Set());
    await database.write({ ops, audioDeletions: deletions, logs: importedLogs });
    const index = storedIsNew ? lighten(typed, "all") : typed;
    const store = new Store(root, index, database, audioCleanupEnabled);
    await store.drainAudioDeletions();
    return store;
  }
  async close() {
    await this.database.close();
  }
  indexJson(): Json {
    return clone(this.data) as unknown as Json;
  }
  async dataJson(): Promise<Json> {
    const data = await this.database.load();
    if (data === undefined) throw Error("Biblioteca sin inicializar");
    return data;
  }
  settingsJson(): Json {
    return clone(this.data.settings) as unknown as Json;
  }
  edit(): LibraryData {
    return clone(this.data);
  }
  async reload() {
    const stored = await this.database.loadIndex();
    if (stored === undefined) throw Error("Biblioteca sin inicializar");
    this.data = readLibraryData(stored);
  }
  async drainAudioDeletions() {
    if (!this.audioCleanupEnabled) return;
    const audioRoot = audioCopyRoot(this.root);
    for (const deletion of await this.database.pendingAudioDeletions()) {
      let metadata;
      try {
        metadata = lstatSync(deletion.path);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") {
          await this.database.completeAudioDeletion(deletion.id);
          continue;
        }
        throw Error(`No se puede comprobar el audio pendiente: ${(error as Error).message}`);
      }
      if (!metadata.isFile()) throw Error("La copia pendiente no es un archivo normal");
      if (metadata.dev !== deletion.device || metadata.ino !== deletion.inode) throw Error("La copia de audio pendiente cambió desde el descarte");
      let canonical: string;
      try {
        canonical = realpathSync(deletion.path);
      } catch (error) {
        throw Error(`No se puede comprobar el audio pendiente: ${(error as Error).message}`);
      }
      if (canonical !== deletion.path || !canonical.startsWith(`${audioRoot}/`)) throw Error("La copia pendiente está fuera de la biblioteca");
      if (referencesAudio(this.data, canonical)) throw Error("Otra grabación conserva la copia de audio pendiente");
      try {
        unlinkSync(deletion.path);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw Error(`No se pudo borrar el audio local: ${(error as Error).message}`);
      }
      await this.database.completeAudioDeletion(deletion.id);
    }
  }
  async replace(value: Json) {
    const typed = readLibraryData(value);
    if (typed.schemaVersion !== 1) throw Error("Versión de biblioteca incompatible");
    const before = readLibraryData(await this.dataJson());
    const ops = changes(before, typed, "all");
    await this.database.write({ ops });
    this.data = lighten(typed, "all");
  }
  async replaceCatalog(value: Json, aliases: Map<string, string>) {
    const next = readLibraryData(value);
    const ops = changes(this.data, next, new Set());
    await this.database.write({ ops, recipeAliases: aliases });
    this.data = next;
  }
  private async commit(data: LibraryData) {
    if (data.schemaVersion !== 1) throw Error("Versión de biblioteca incompatible");
    const ops = changes(this.data, data, new Set());
    await this.database.write({ ops });
    this.data = data;
  }
  private static scopedWrite(before: LibraryData, after: LibraryData, writeScope: WriteScope): LibraryWrite {
    return scopedWrite(writeScope, changes(before, after, writeScope.fullRecordings));
  }
  async appendLog(p: Json) {
    const level = typeof (p as Record<string, Json>).level === "string" ? ((p as Record<string, Json>).level as string) : "info";
    if (!["info", "warn", "error"].includes(level)) throw Error("Nivel de registro no válido");
    await this.database.appendLog({ id: newId(), at: now(), message: text(p, "message"), level, recordingId: field(p, "recordingId"), recipeId: field(p, "recipeId") });
  }
  async logList(p: Json): Promise<Json[]> {
    return this.database.logList(parseLogQuery(p));
  }
  async recording(recordId: string): Promise<Record<string, Json>> {
    const found = await this.database.recording(recordId);
    if (found === undefined) throw Error("Grabación no encontrada");
    return found as Record<string, Json>;
  }
  recordingForWrite(recordId: string): Recording {
    return recordingForWrite(this.data, recordId);
  }
  item(collection: string, itemId: string): Record<string, Json> {
    return item(this.data, collection, itemId);
  }
  audio(recordId: string): string {
    return audio(this.data, this.root, recordId);
  }
  private async recordingEdit(key: string): Promise<LibraryData> {
    const data = this.edit();
    const index = data.recordings.findIndex((record) => record.id === key);
    if (index < 0) throw Error("Grabación no encontrada");
    data.recordings[index] = readRecording(await this.recording(key));
    return data;
  }
  library(): Record<string, Json> {
    return library(this.data, this.root);
  }
  async snapshot(): Promise<Record<string, Json>> {
    const value = await this.dataJson();
    const result = value as Record<string, Json>;
    result.settings = redactedSettings(result.settings);
    result.dataPath = this.root;
    markCredentials(this.root, result);
    return result;
  }
  async runtimeContext(recordingId?: string): Promise<Record<string, Json>> {
    return runtimeContext(this.data, this.root, this, recordingId);
  }

  async mutate(method: string, p: Json): Promise<Json> {
    if (method.startsWith("note_draft_")) return this.draftCommand(method, p);
    if (method === "log") {
      await this.appendLog(p);
      return null;
    }
    const guarded = ["recording_update", "recording_remove_audio"].includes(method)
      ? text(p, "id")
      : ["version_save", "version_select", "version_update", "publication_save", "publication_remove", "account_effect_begin", "account_effect_finish"].includes(method)
        ? text(p, "recordingId")
        : undefined;
    if (guarded !== undefined) this.recordingForWrite(guarded);
    const fullRecording = ["version_save", "version_select", "version_update", "publication_save", "publication_remove", "account_effect_begin", "account_effect_finish"].includes(method) ? text(p, "recordingId") : undefined;
    const before = fullRecording !== undefined ? await this.recordingEdit(fullRecording) : this.edit();
    const next = clone(before);
    const writeScope = scope({ fullRecordings: new Set(fullRecording !== undefined ? [fullRecording] : []) });
    let deleteAfterCommit: string | undefined;
    const audioToDelete: AudioDeletion[] = [];
    let voiceSave: VersionCommit | undefined;
    let result: Json;
    switch (method) {
      case "recording_update":
      case "recording_abandoned":
      case "recording_discard":
      case "recording_remove_audio":
      case "recording_delete": {
        const outcome = await this.mutateRecording(next, method, p, audioToDelete);
        result = outcome.result;
        deleteAfterCommit = outcome.deleteAfterCommit;
        break;
      }
      case "version_save":
      case "version_select":
      case "version_update": {
        const outcome = await this.mutateVersion(next, method, p);
        result = outcome.result;
        voiceSave = outcome.voiceSave;
        break;
      }
      case "config_save":
      case "config_remove": {
        const outcome = this.mutateConfiguration(next, method, p);
        result = outcome.result;
        deleteAfterCommit = outcome.deleteAfterCommit;
        break;
      }
      case "settings_save":
        updateSettings(next.settings, field(p, "settings"));
        result = redactedSettings(clone(next.settings) as unknown as Json);
        break;
      case "publication_save": {
        const record = recordMut(next, text(p, "recordingId"));
        const key = text(p, "destinationId");
        const { recordingId: _recordingId, ...publication } = object(p, "Recibo inválido");
        publication.updatedAt = now();
        const publications = record.publications;
        if (!Array.isArray(publications)) throw Error("Publicaciones inválidas");
        const index = publications.findIndex((item) => isObject(item) && item.destinationId === key);
        if (index >= 0) publications[index] = publication;
        else publications.push(publication);
        result = null;
        break;
      }
      case "publication_remove": {
        const record = recordMut(next, text(p, "recordingId"));
        const key = text(p, "destinationId");
        if (!Array.isArray(record.publications)) throw Error("Publicaciones inválidas");
        record.publications = record.publications.filter((item) => !isObject(item) || item.destinationId !== key);
        result = null;
        break;
      }
      case "account_effect_begin":
      case "account_effect_finish": {
        const record = recordMut(next, text(p, "recordingId")) as Record<string, unknown>;
        if (method === "account_effect_begin") record.accountEffectPending = true;
        else delete record.accountEffectPending;
        result = null;
        break;
      }
      default:
        throw Error(`Operación desconocida: ${method}`);
    }
    const index = lighten(clone(next), writeScope.fullRecordings);
    const write = Store.scopedWrite(before, next, writeScope);
    let taught: [string, boolean] | undefined;
    if (voiceSave) {
      const [recordingId, versionId, voices, teaching] = voiceSave;
      taught = [recordingId, teaching !== undefined];
      write.versionVoices = [versionId, voices];
      if (teaching) write.teaching = teaching;
    }
    write.audioDeletions = audioToDelete;
    const learned = await this.database.write(write);
    this.data = index;
    if (taught) {
      this.pendingVoices.delete(taught[0]);
      if (taught[1] && isObject(result)) (result as Record<string, Json>).learnedVoice = learned;
    }
    if (method === "recording_discard") {
      this.pendingVoices.delete(text(p, "id"));
      await this.drainAudioDeletions();
    }
    if (deleteAfterCommit !== undefined) {
      try {
        unlinkSync(deleteAfterCommit);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw Error(`El cambio está guardado, pero no se pudo eliminar el archivo local: ${(error as Error).message}`);
      }
    }
    return result;
  }
  private async mutateRecording(next: LibraryData, method: string, p: Json, audioToDelete: AudioDeletion[]): Promise<{ result: Json; deleteAfterCommit?: string }> {
    switch (method) {
      case "recording_update": {
        const record = recordMut(next, text(p, "id"));
        updateRecording(record, p);
        return { result: clone(record) as unknown as Json };
      }
      case "recording_abandoned": {
        const path = text(p, "path");
        const sourceKey = typeof (p as Record<string, Json>).sourceKey === "string" ? ((p as Record<string, Json>).sourceKey as string) : undefined;
        const key = `empty-${createHash("sha256").update(sourceKey ?? path).digest("hex")}`;
        const createdAt = typeof (p as Record<string, Json>).modifiedAt === "string" ? ((p as Record<string, Json>).modifiedAt as string) : now();
        const existing = next.recordings.find((record) => record.id === key);
        if (existing) return { result: clone(existing) as unknown as Json };
        const title = typeof (p as Record<string, Json>).title === "string" ? ((p as Record<string, Json>).title as string) : fileStem(path) || "Grabación vacía";
        const record: Json = { id: key, title, createdAt, source: path, sourceKey: sourceKey ?? null, audioPath: null, duration: 0, status: "failed", error: "La grabación permanece vacía tras una hora; vuelve a intentarlo cuando contenga audio.", recipeId: null, versions: [], publications: [] };
        next.recordings.unshift(readRecording(record));
        return { result: record };
      }
      case "recording_discard": {
        const key = text(p, "id");
        const prior = clone(recordMut(next, key));
        const index = next.recordings.findIndex((record) => record.id === key);
        const tombstone = readRecording(discardedRecord(prior as unknown as Json));
        next.recordings[index] = tombstone;
        if (typeof prior.audioPath === "string" && prior.audioPath) {
          const copy = audioCopyToDelete(this.root, next, prior.audioPath);
          if (copy) audioToDelete.push(copy);
        }
        return { result: clone(tombstone) as unknown as Json };
      }
      case "recording_remove_audio": {
        const key = text(p, "id");
        const path = this.audio(key);
        const record = recordMut(next, key);
        record.audioPath = null;
        return { result: null, deleteAfterCommit: path };
      }
      case "recording_delete": {
        const key = text(p, "id");
        const record = await this.recording(key);
        let deleteAfterCommit: string | undefined;
        if (typeof record.audioPath === "string" && existsSync(record.audioPath)) deleteAfterCommit = this.audio(key);
        next.recordings = next.recordings.filter((item) => item.id !== key);
        return { result: null, ...(deleteAfterCommit ? { deleteAfterCommit } : {}) };
      }
      default:
        throw Error(`Operación desconocida: ${method}`);
    }
  }
  private async mutateVersion(next: LibraryData, method: string, p: Json): Promise<{ result: Json; voiceSave?: VersionCommit }> {
    switch (method) {
      case "version_save": {
        const recordingId = text(p, "recordingId");
        const record = recordMut(next, recordingId);
        const params = p as Record<string, Json>;
        let transcript: Transcript;
        try {
          transcript = readVersion({ id: "x", transcript: stripEmbeddings(params.transcript ?? null) }, "Transcripción inválida").transcript as Transcript;
          if (!transcript) throw Error("Transcripción inválida");
        } catch {
          throw Error("Transcripción inválida");
        }
        let teaching: Teaching | undefined;
        let voices: SpeakerVoice[];
        const source = params.sourceVersionId;
        if (typeof source === "string") {
          const sourceVersion = (record.versions ?? []).find((version) => version.id === source);
          if (!sourceVersion) throw Error("La versión de origen no pertenece a la grabación");
          voices = await this.database.versionVoices(source);
          if (isObject(params.teaching)) {
            const speaker = text(params.teaching, "speaker");
            const person = text(params.teaching, "person");
            teaching = { person, voices: voices.filter((voice) => voice.speaker === speaker).map((voice) => ({ ...voice })), source: recordingId, existingOnly: params.teaching.existingOnly === true };
          }
          if (!sourceVersion.transcript) throw Error("Transcripción de origen inválida");
          relabelVoices(sourceVersion.transcript, transcript, voices);
        } else {
          if (params.teaching !== undefined && params.teaching !== null) throw Error("La corrección no indica su versión de origen");
          voices = this.pendingVoices.get(recordingId)?.map((voice) => ({ ...voice })) ?? [];
        }
        const version = createVersion(params, transcript, voices.length > 0);
        const result = clone(version) as unknown as Json;
        appendVersion(record, version);
        return { result, voiceSave: [recordingId, version.id, voices, teaching] };
      }
      case "version_select": {
        const record = recordMut(next, text(p, "recordingId"));
        const id = text(p, "versionId");
        if (!(record.versions ?? []).some((version) => version.id === id)) throw Error("Versión no encontrada");
        record.currentVersionId = id;
        return { result: null };
      }
      case "version_update": {
        const record = recordMut(next, text(p, "recordingId"));
        const key = text(p, "versionId");
        const versions = record.versions;
        if (!Array.isArray(versions)) throw Error("Versiones inválidas");
        const version = versions.find((item) => item.id === key);
        if (!version) throw Error("Versión no encontrada");
        const params = p as Record<string, Json>;
        if ("digest" in params) version.digest = params.digest ?? null;
        if ("data" in params) version.data = params.data ?? null;
        return { result: clone(version) as unknown as Json };
      }
      default:
        throw Error(`Operación desconocida: ${method}`);
    }
  }
  private mutateConfiguration(next: LibraryData, method: string, p: Json): { result: Json; deleteAfterCommit?: string } {
    switch (method) {
      case "config_save": {
        const collection = collectionName(p);
        catalog(next, collection);
        const item = clone(field(p, "item"));
        if (!isObject(item)) throw Error("Escribe un nombre");
        const key = text(item, "id");
        if (collection === "accounts" || collection === "resolvers") safeId(key);
        if (typeof item.name !== "string" || !item.name.trim()) throw Error("Escribe un nombre");
        if (collection === "resolvers") {
          if (!["stt", "llm"].includes(String(item.role))) throw Error("Papel de resolutor inválido");
          const addedModel = key !== "local-stt" && isLocalSttId(key);
          if (addedModel && (item.role !== "stt" || localSttId(String(item.model)) !== key)) throw Error("El modelo no corresponde a este Whisper local");
          if (!["local-stt", "local-llm"].includes(key) && !addedModel) item.local = false;
          else {
            item.local = true;
            item.enabled = true;
          }
        }
        if (collection === "accounts") {
          if (!["notion", "okf"].includes(String(item.provider))) throw Error("Proveedor no válido");
          if (item.grant !== undefined) validateAccountGrant(item.grant);
          let old: Record<string, Json> | undefined;
          try {
            old = this.item("accounts", key);
          } catch {
            old = undefined;
          }
          if (old && old.provider !== item.provider) throw Error("El identificador pertenece a otro proveedor");
          if (item.provider === "notion") item.origin = "https://api.notion.com";
          if (typeof item.folder === "string" && item.folder) {
            let path: string;
            try {
              path = realpathSync(item.folder);
            } catch (error) {
              throw Error(`Carpeta inaccesible: ${(error as Error).message}`);
            }
            if (!statSync(path).isDirectory()) throw Error("Elige una carpeta");
            item.folder = path;
          }
        }
        for (const secret of ["token", "secret", "credential", "hasCredential", "bundleFingerprint", "programFingerprint"]) delete item[secret];
        const items = catalog(next, collection);
        const index = items.findIndex((old) => isObject(old) && old.id === key);
        if (index >= 0) {
          const old = items[index] as Record<string, Json>;
          for (const program of ["bundle", "program"]) if (!(program in item) && program in old) item[program] = old[program] as Json;
          items[index] = clone(item);
        } else {
          if (collection === "accounts" || collection === "resolvers") {
            const orphan = credentialPath(this.root, key);
            if (existsSync(orphan)) {
              try {
                unlinkSync(orphan);
              } catch (error) {
                throw Error(`No se pudo retirar la credencial de una cuenta anterior: ${(error as Error).message}`);
              }
            }
          }
          items.push(clone(item));
        }
        return { result: item };
      }
      case "config_remove": {
        const collection = collectionName(p);
        const key = text(p, "id");
        if (["local-llm", "default"].includes(key)) throw Error("Esta opción viene de serie y no se puede quitar");
        if (collection === "accounts" && next.recordings.some((record) => (record.publications ?? []).some((publication) => isObject(publication) && publication.accountId === key)))
          throw Error("Retira las publicaciones de esta cuenta antes de eliminarla");
        setCatalog(next, collection, catalog(next, collection).filter((item) => !isObject(item) || item.id !== key));
        if (collection === "resolvers" || collection === "destinations") pruneRecipes(next, key);
        if (next.settings.defaultRecipeId === key) next.settings.defaultRecipeId = "default";
        const result: { result: Json; deleteAfterCommit?: string } = { result: null };
        if (collection === "accounts" || collection === "resolvers") result.deleteAfterCommit = credentialPath(this.root, key);
        return result;
      }
      default:
        throw Error(`Operación desconocida: ${method}`);
    }
  }
  credential(key: string): string | undefined {
    try {
      return readFileSync(credentialPath(this.root, key), "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw Error(`No se puede leer la credencial: ${(error as Error).message}`);
    }
  }
  async saveConnector(accountValue: Json, destinationValue: Json) {
    const accounts = catalog(this.data, "accounts");
    const destinations = catalog(this.data, "destinations");
    const key = text(accountValue, "id");
    safeId(key);
    const provider = text(accountValue, "provider");
    const builtin = ["notion", "okf"].includes(provider);
    const definition = builtin ? undefined : this.item("providers", provider);
    const destinationInput = destinationValue as Record<string, Json>;
    if (!isObject(destinationValue) || destinationInput.id !== key || destinationInput.account !== key || destinationInput.provider !== provider || (builtin && "program" in destinationInput) || typeof destinationInput.enabled !== "boolean")
      throw Error("Cuenta y destino del conector no coinciden");
    if (!isObject(accountValue) || !isObject(destinationInput.configuration)) throw Error("Configuración del conector inválida");
    if (accounts.some((old) => isObject(old) && old.id === key && old.provider !== provider) || destinations.some((old) => isObject(old) && old.id === key && old.managed !== true && old.program !== null && old.program !== undefined))
      throw Error("El identificador pertenece a otro conector");
    const account = clone(accountValue) as Record<string, Json>;
    const destination = clone(destinationValue) as Record<string, Json>;
    if (account.grant !== undefined) validateAccountGrant(account.grant);
    destination.managed = true;
    account.enabled = typeof account.enabled === "boolean" ? account.enabled : true;
    if (definition) {
      if (definition.unavailable === true) throw Error("Proveedor no disponible");
      if (account.grant !== undefined) {
        const grant = account.grant as Record<string, Json>;
        if (!accessEquivalent(grant, definition)) throw Error("La autorización no coincide con el proveedor instalado");
        let old: Record<string, Json> | undefined;
        try {
          old = this.item("accounts", key);
        } catch {
          old = undefined;
        }
        if (old && isObject(old.grant) && !sameAuthority(old.grant, grant) && this.credential(key) !== undefined)
          throw Error("Retira la credencial antes de cambiar el origen o la autenticación");
        if (grant.capability === "http") {
          account.origin = grant.origin ?? null;
          delete account.folder;
        } else {
          if (typeof account.folder !== "string") throw Error("Carpeta inválida");
          const canonical = canonicalFolder(account.folder);
          account.folder = canonical;
          (destination.configuration as Record<string, Json>).folder = canonical;
        }
      } else if (account.enabled !== false || destination.enabled !== false) throw Error("Falta la autorización de la cuenta");
      destination.program = definition.program ?? null;
      destination.programFingerprint = definition.programFingerprint ?? null;
    } else if (provider === "notion") account.origin = "https://api.notion.com";
    else {
      const folder = (destination.configuration as Record<string, Json>).folder;
      if (typeof folder !== "string") throw Error("Carpeta OKF inválida");
      const canonical = folder ? canonicalFolder(folder) : "";
      account.folder = canonical;
      (destination.configuration as Record<string, Json>).folder = canonical;
    }
    for (const secret of ["token", "secret", "credential", "hasCredential"]) delete account[secret];
    if (!accounts.some((old) => isObject(old) && old.id === key)) {
      const orphan = credentialPath(this.root, key);
      if (existsSync(orphan)) {
        try {
          unlinkSync(orphan);
        } catch (error) {
          throw Error(`No se pudo retirar una credencial anterior: ${(error as Error).message}`);
        }
      }
    }
    const next = this.edit();
    for (const [collection, value] of [["accounts", account], ["destinations", destination]] as const) {
      const items = catalog(next, collection);
      const index = items.findIndex((old) => isObject(old) && old.id === key);
      if (index >= 0) items[index] = value;
      else items.push(value);
    }
    await this.commit(next);
  }
  async removeConnector(key: string) {
    this.item("accounts", key);
    const destination = this.item("destinations", key);
    if (destination.account !== key || (destination.managed !== true && destination.program !== null && destination.program !== undefined))
      throw Error("El conector de la app no coincide con su cuenta y destino");
    const next = this.edit();
    for (const collection of ["accounts", "destinations"]) setCatalog(next, collection, catalog(next, collection).filter((item) => !isObject(item) || item.id !== key));
    pruneRecipes(next, key);
    const credential = credentialPath(this.root, key);
    await this.commit(next);
    try {
      unlinkSync(credential);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw Error(`El conector se quitó, pero no se pudo borrar su token: ${(error as Error).message}`);
    }
  }
  async authorizeWatchedFolder(folderId: string | undefined, path: string, name: string | undefined, style: string, bookmark: number[]): Promise<Json> {
    if (!bookmark.length && folderBookmarkRequired()) throw Error("La autorización de carpeta está vacía");
    // Linux has no bookmarks: the folder is read through its path.
    const access: Json = bookmark.length ? bookmark : null;
    if (!STYLES.includes(style)) throw Error("Estilo de carpeta desconocido");
    const canonical = canonicalFolder(path);
    const next = this.edit();
    const folders = foldersOf(next);
    let found: number | undefined;
    if (folderId !== undefined) {
      found = folders.findIndex((folder) => folder.id === folderId);
      if (found < 0) throw Error("La carpeta vigilada ya no existe");
    } else {
      const index = folders.findIndex((folder) => sameFolder(folder.path, canonical));
      found = index >= 0 ? index : undefined;
    }
    let saved: Json;
    if (found !== undefined) {
      const existing = folders[found]!;
      let relocation = false;
      if (!sameFolder(existing.path, canonical)) {
        if (existsSync(existing.path)) throw Error("La carpeta elegida no corresponde a la que se reautoriza");
        relocation = true;
      }
      if (relocation && folders.some((folder, index) => index !== found && sameFolder(folder.path, canonical))) throw Error("La nueva ubicación ya pertenece a otra carpeta vigilada");
      if (relocation) existing.path = canonical;
      existing.accessBookmark = access;
      delete (existing as Record<string, unknown>).authorizationSaved;
      saved = clone(existing) as unknown as Json;
    } else {
      const defaultName = canonical.split("/").filter(Boolean).at(-1) ?? "Carpeta";
      const folder: Json = { id: newId(), path: canonical, name: name?.trim() ? name : defaultName, style, enabled: true, accessBookmark: access };
      folders.push(readSettings({ watchedFolders: [folder] }).watchedFolders![0]!);
      saved = folder;
    }
    await this.commit(next);
    return redactedFolder(saved);
  }
  async seedVoiceMemos(path: string): Promise<boolean> {
    const settings = this.data.settings;
    if (settings.voiceMemosSeeded === true) return false;
    const adopted = settings.legacyWatchAdopted === true;
    const present = foldersOf(this.data).some((folder) => folder.style === "voiceMemos" || sameFolder(folder.path, path));
    const seeds = !adopted && !present;
    const next = this.edit();
    if (seeds) foldersOf(next).push(readSettings({ watchedFolders: [{ id: newId(), path, name: "Notas de Voz", style: "voiceMemos", enabled: true }] }).watchedFolders![0]!);
    next.settings.voiceMemosSeeded = true;
    await this.commit(next);
    return seeds;
  }
  watchedFolderBookmarks(): [string, string, number[]][] {
    return foldersOf(this.data)
      .filter((folder) => folder.enabled !== false && folder.accessBookmark !== null && folder.accessBookmark !== undefined)
      .map((folder) => [folder.id, folder.path, bookmarkBytes(folder.accessBookmark as Json)]);
  }
  async refreshWatchedFolderBookmark(folderId: string, previous: number[], resolvedPath: string, replacement?: number[]): Promise<boolean> {
    if (replacement !== undefined && !replacement.length) throw Error("La autorización renovada está vacía");
    const next = this.edit();
    const folder = foldersOf(next).find((item) => item.id === folderId);
    if (!folder) return false;
    if (folder.accessBookmark === null || folder.accessBookmark === undefined) return false;
    if (!equal(bookmarkBytes(folder.accessBookmark as Json), previous)) return false;
    folder.path = canonicalFolder(resolvedPath);
    if (replacement !== undefined) folder.accessBookmark = replacement;
    await this.commit(next);
    return true;
  }
  async jobs(): Promise<Json[]> {
    return this.database.jobs();
  }
  jobsFor(recordingId: string): Promise<Json[]> {
    return this.database.jobsFor(recordingId);
  }
  async jobSave(job: Json) {
    this.recordingForWrite(text(job, "recordingId"));
    await this.database.saveJob(job);
  }
  jobRemove(id: string) {
    return this.database.removeJob(id);
  }
  memoryKey(recordingId: string, versionId: string, fingerprint: string): string {
    return memoryKey(this.data, recordingId, versionId, fingerprint);
  }
  memoryRecall(recordingId: string, versionId: string, fingerprint: string): Promise<Json | undefined> {
    return this.database.recall(this.memoryKey(recordingId, versionId, fingerprint));
  }
  memoryKeep(recordingId: string, versionId: string, fingerprint: string, value: Json) {
    return this.database.keep(this.memoryKey(recordingId, versionId, fingerprint), recordingId, value);
  }
  async traceSave(trace: Json) {
    this.recordingForWrite(text(trace, "recordingId"));
    const entry = { ...(trace as Record<string, Json>) };
    if (typeof entry.id !== "string" || !entry.id) entry.id = newId();
    await this.database.traceSave(entry);
  }
  traceList(recordingId?: string) {
    return this.database.traceList(recordingId);
  }
  knowledgePrepare(epoch: string) {
    return this.database.knowledgePrepare(epoch);
  }
  knowledgeChange() {
    return this.database.knowledgeChange();
  }
  knowledgeChanges(limit: number) {
    return this.database.knowledgeChanges(limit);
  }
  knowledgeAck(key: string, revision: string) {
    return this.database.knowledgeAck(key, revision);
  }
  people() {
    return this.database.people();
  }
  knownVoices(): Promise<KnownVoice[]> {
    return this.database.knownVoices();
  }
  addPersonVoice(name: string, voice: SpeakerVoice, source: string) {
    return this.database.addPersonVoice(name, voice, source);
  }
  setPersonColor(name: string, color: string) {
    return this.database.setPersonColor(name, color);
  }
  renamePerson(name: string, newName: string) {
    return this.database.renamePerson(name, newName);
  }
  removePersonVoice(id: string) {
    return this.database.removePersonVoice(id);
  }
  removePerson(name: string) {
    return this.database.removePerson(name);
  }
  versionVoices(id: string) {
    return this.database.versionVoices(id);
  }
  async recognizeTranscription(recordingId: string, transcriptValue: Json): Promise<Json> {
    this.recordingForWrite(recordingId);
    this.pendingVoices.delete(recordingId);
    if (!isObject(transcriptValue)) throw Error("Transcripción inválida");
    const { voices: rawVoices, ...rest } = transcriptValue;
    const voices = rawVoices === undefined ? [] : rawVoices;
    if (!Array.isArray(voices)) throw Error("Huellas de voz inválidas");
    const own: SpeakerVoice[] = voices.map((voice) => {
      if (!validVoice(voice) || !voice.speaker || !voice.model || !voice.embedding.length || voice.embedding.some((value) => !Number.isFinite(value)))
        throw Error("Huellas de voz inválidas");
      return { speaker: voice.speaker, model: voice.model, embedding: [...voice.embedding] };
    });
    const transcript = stripEmbeddings(rest) as Record<string, Json>;
    const segments = Array.isArray(transcript.segments) ? transcript.segments : undefined;
    if (segments) for (const segment of segments) if (isObject(segment)) delete segment.personId;
    const recognized: Json[] = [];
    if (own.length && segments && segments.length) {
      const known = await this.knownVoices();
      for (const recognition of recognize(own, known)) {
        if (segments.some((segment) => isObject(segment) && segment.speaker === recognition.person)) continue;
        for (const segment of segments)
          if (isObject(segment) && segment.speaker === recognition.speaker) {
            segment.speaker = recognition.person;
            segment.personId = recognition.personId;
          }
        for (const voice of own) if (voice.speaker === recognition.speaker) voice.speaker = recognition.person;
        recognized.push({ speaker: recognition.speaker, person: recognition.person, personId: recognition.personId, distance: recognition.distance });
      }
    }
    transcript.recognitions = recognized;
    if (own.length) this.pendingVoices.set(recordingId, own);
    else this.pendingVoices.delete(recordingId);
    return transcript;
  }
  async import(source: string, recipeId?: string): Promise<Json> {
    return this.importInternal(source, recipeId, undefined, false);
  }
  async importRecoveredCapture(source: string): Promise<Json> {
    return this.importInternal(source, undefined, undefined, true);
  }
  async importWithMetadata(source: string, recipeId: string | undefined, title: string, startedAt: Date, sourceKey: string): Promise<Json> {
    if (!sourceKey || sourceKey.length > 4096) throw Error("Identidad de origen inválida");
    return this.importInternal(source, recipeId, { title, startedAt, sourceKey }, false);
  }
  private async importInternal(source: string, recipeId: string | undefined, metadata: WatcherMetadata | undefined, recoveredCapture: boolean): Promise<Json> {
    const staged = stageAudio(this.root, source, recoveredCapture);
    return this.importStagedInternal(staged, source, recipeId, metadata);
  }
  importStaged(staged: StagedAudio, source: string, recipeId?: string): Promise<Json> {
    return this.importStagedInternal(staged, source, recipeId, undefined);
  }
  importStagedWithMetadata(staged: StagedAudio, source: string, title: string, startedAt: Date, sourceKey: string): Promise<Json> {
    if (!sourceKey || sourceKey.length > 4096) throw Error("Identidad de origen inválida");
    return this.importStagedInternal(staged, source, undefined, { title, startedAt, sourceKey });
  }
  private async importStagedInternal(staged: StagedAudio, source: string, recipeId: string | undefined, metadata: WatcherMetadata | undefined): Promise<Json> {
    if (staged.root !== this.root || staged.source !== source) {
      staged.discard();
      throw Error("La copia preparada no corresponde a esta importación");
    }
    const { temp, hash: contentHash, digest: contentDigest, ext, captureDate } = staged;
    const sourceText = source;
    const discardTemp = () => rmSync(temp, { force: true });
    if (!metadata) {
      const existing = this.data.recordings.find((record) => record.audioHash === contentHash && record.status !== "failed");
      if (existing) {
        discardTemp();
        return clone(existing) as unknown as Json;
      }
    }
    const prior = metadata ? this.priorForWatched(source, sourceText, metadata.sourceKey) : undefined;
    if (prior && prior.status === "discarded") {
      discardTemp();
      return clone(prior) as unknown as Json;
    }
    const abandoned = this.data.recordings.find((record) => record.source === sourceText && record.status === "failed" && (record.audioPath === null || record.audioPath === undefined) && record.id.startsWith("empty-"));
    const key = prior?.id ?? abandoned?.id ?? (metadata ? `watch-${createHash("sha256").update(metadata.sourceKey).digest("hex")}` : contentHash);
    if (prior) {
      let changed: boolean;
      if (typeof prior.audioHash === "string") changed = prior.audioHash !== contentHash;
      else {
        try {
          changed = !fileHash(this.audio(key)).equals(contentDigest);
        } catch {
          changed = true;
        }
      }
      if (metadata && (!changed || prior.status === "discarded")) {
        discardTemp();
        const next = this.edit();
        const existing = recordMut(next, key);
        existing.source = sourceText;
        existing.sourceKey = metadata.sourceKey;
        if (!changed) existing.audioHash = contentHash;
        if (prior.legacyKey === null || prior.legacyKey === undefined) {
          existing.title = metadata.title;
          existing.createdAt = importCreatedAt(metadata.startedAt, metadata.startedAt);
        }
        const record = clone(existing) as unknown as Json;
        await this.commit(next);
        return record;
      }
      if (changed && (await this.jobsFor(key)).some((job) => isObject(job) && ["queued", "running", "retry"].includes(String(job.state)))) {
        discardTemp();
        throw Error("El audio cambió mientras hay un trabajo activo; se reintentará cuando termine");
      }
    }
    if (!metadata && !abandoned) {
      const existing = this.data.recordings.find((record) => record.id === key);
      if (existing) {
        discardTemp();
        return clone(existing) as unknown as Json;
      }
    }
    const filename = metadata ? `${key}-${contentHash}.${ext}` : `${key}.${ext}`;
    const target = join(this.root, "audio", filename);
    const createdCopy = linkStaged(temp, target);
    const next = this.edit();
    const oldAudio = typeof prior?.audioPath === "string" ? prior.audioPath : undefined;
    const existingIndex = next.recordings.findIndex((record) => record.id === key);
    let record: Json;
    if (existingIndex >= 0) {
      const recording = next.recordings[existingIndex]!;
      const changedAudio = recording.audioPath !== target;
      recording.audioPath = target;
      recording.audioHash = contentHash;
      recording.source = sourceText;
      if (changedAudio || recording.status === "failed") {
        recording.status = "pending";
        recording.error = null;
      }
      if (recipeId !== undefined) recording.recipeId = recipeId;
      if (metadata) {
        recording.title = metadata.title;
        recording.createdAt = importCreatedAt(metadata.startedAt, metadata.startedAt);
        recording.sourceKey = metadata.sourceKey;
      }
      record = clone(recording) as unknown as Json;
    } else {
      const title = metadata ? metadata.title : fileStem(source) || "Grabación";
      const createdAt = metadata ? importCreatedAt(metadata.startedAt, metadata.startedAt) : importCreatedAt(captureDate, new Date());
      record = { id: key, status: "pending", title, createdAt, sourceKey: metadata?.sourceKey ?? null, source: sourceText, audioPath: target, audioHash: contentHash, duration: 0, recipeId: recipeId ?? null, versions: [], publications: [] };
      next.recordings.unshift(readRecording(record));
    }
    try {
      await this.commit(next);
    } catch (error) {
      if (createdCopy) rmSync(target, { force: true });
      throw error;
    }
    if (oldAudio !== undefined && oldAudio !== target && oldAudio.startsWith(join(this.root, "audio")) && existsSync(oldAudio)) {
      try {
        unlinkSync(oldAudio);
      } catch (error) {
        throw Error(`La importación está guardada, pero no se pudo retirar el audio anterior: ${(error as Error).message}`);
      }
    }
    return record;
  }
  private priorForWatched(source: string, sourceText: string, sourceKey: string): Recording | undefined {
    const records = this.data.recordings;
    const bySourceKey = records.find((record) => record.sourceKey === sourceKey);
    if (bySourceKey) return clone(bySourceKey);
    const inode = sourceKey.startsWith("voiceMemos:") ? sourceKey.split("/").at(-1) : undefined;
    if (inode !== undefined) {
      const legacy = records.find((record) => {
        const sameParent = typeof record.source === "string" && dirname(record.source) === dirname(source);
        const legacyInode = record.legacyKey === inode || record.legacyKey === `Notas de Voz/${inode}`;
        return typeof record.sourceKey === "string" && record.sourceKey.startsWith("swift:") && sameParent && legacyInode;
      });
      if (legacy) return clone(legacy);
    }
    const bySource = records.find((record) => typeof record.sourceKey === "string" && record.sourceKey.startsWith("swift:") && typeof record.legacyKey === "string" && record.source === sourceText);
    if (bySource) return clone(bySource);
    const discarded = records.find((record) => record.status === "discarded" && record.source === sourceText);
    return discarded ? clone(discarded) : undefined;
  }
  private async draftCommand(method: string, p: Json): Promise<Json> {
    const key = text(p, "recordingId");
    this.recordingForWrite(key);
    const storedValue = await this.database.draftRead(key, false);
    const stored = storedValue === undefined ? undefined : readDraft(storedValue);
    if (stored && stored.recordingId !== key) throw Error("El borrador no pertenece a la grabación");
    if (method === "note_draft_get") return stored === undefined ? null : (clone(stored) as unknown as Json);
    const before = await this.recordingEdit(key);
    const record = before.recordings.find((item) => item.id === key);
    if (!record) throw Error("Grabación no encontrada");
    const base = currentVersion(record);
    if (method === "note_draft_begin") {
      if (stored) return clone(stored) as unknown as Json;
      const draft = newDraft(key, base, record);
      const result = clone(draft) as unknown as Json;
      await this.database.write(Store.scopedWrite(before, before, scope({ draftChange: [key, result], fullRecordings: new Set([key]) })));
      return result;
    }
    const { draftId, revision } = draftRequest(p);
    if (method === "note_draft_commit") {
      const receipt = await this.database.draftRead(draftId, true);
      if (receipt !== undefined) {
        if (!isObject(receipt) || receipt.recordingId !== key || receipt.revision !== revision) throw Error("La confirmación del borrador no coincide");
        const version = (record.versions ?? []).find((item) => item.id === receipt.versionId);
        if (!version) throw Error("Versión confirmada no encontrada");
        return { version: clone(version) as unknown as Json, created: receipt.created ?? null };
      }
    }
    if (!stored) throw Error("El borrador ya no existe");
    const draft: NoteDraft = clone(stored);
    if (draft.id !== draftId || draft.revision !== revision) throw Error("El borrador cambió en otra ventana. Vuelve a cargarlo antes de guardar.");
    const writeScope = scope({ fullRecordings: new Set([key]) });
    if (method === "note_draft_discard") {
      writeScope.draftChange = [key, null];
      await this.database.write(Store.scopedWrite(before, before, writeScope));
      return null;
    }
    if (draft.baseVersionId !== base.id || draft.baseFingerprint !== draftFingerprint(base, record.title))
      throw Error("La versión de origen cambió. El borrador se conserva; descártalo para editar la versión vigente.");
    if (method === "note_draft_save") {
      const proposed = clone(field(p, "content"));
      if (isObject(proposed) && proposed.transcript !== undefined) proposed.transcript = stripEmbeddings(proposed.transcript as Json);
      draft.content = parseDraftContent(proposed);
      validateContent(draft.content);
      if (draft.content.digest) draft.content.digest.title = draft.content.title;
      if (!Number.isSafeInteger(draft.revision + 1)) throw Error("Revisión agotada");
      draft.revision += 1;
      draft.updatedAt = now();
      const result = clone(draft) as unknown as Json;
      writeScope.draftChange = [key, result];
      await this.database.write(Store.scopedWrite(before, before, writeScope));
      return result;
    }
    if (method === "note_draft_commit") {
      const created = canonical(draft.content) !== canonical(draftContent(record, base));
      let version: Version = clone(base);
      let voices: SpeakerVoice[] = [];
      if (created) {
        if (!base.transcript) throw Error("Transcripción de origen inválida");
        version = { ...version, id: newId(), createdAt: now(), backend: "manual", title: draft.content.title, sourceVersionId: base.id } as Version;
        voices = conservativeVoices(base.transcript, draft.content.transcript, await this.database.versionVoices(base.id));
        version.hasVoices = voices.length > 0;
        version.transcript = draft.content.transcript;
        version.digest = draft.content.digest === null ? null : (draft.content.digest as unknown as Json);
        version.data = draft.content.data;
      }
      const result: Json = { version: clone(version) as unknown as Json, created };
      writeScope.draftChange = [key, null];
      writeScope.draftReceipt = [draft.id, key, { recordingId: key, revision, versionId: version.id, created }];
      const next = clone(before);
      if (created) {
        const target = recordMut(next, key);
        target.title = draft.content.title;
        appendVersion(target, clone(version));
      }
      const index = lighten(clone(next), writeScope.fullRecordings);
      const write = Store.scopedWrite(before, next, writeScope);
      if (created) write.versionVoices = [version.id, voices];
      await this.database.write(write);
      this.data = index;
      return result;
    }
    throw Error(`Operación desconocida: ${method}`);
  }
}
interface WatcherMetadata {
  title: string;
  startedAt: Date;
  sourceKey: string;
}
export function lighten(data: LibraryData, fullRecordings: Children): LibraryData {
  for (const record of data.recordings) {
    if (fullRecordings !== "all" && !fullRecordings.has(record.id)) continue;
    if (Array.isArray(record.versions)) record.versions = record.versions.map(previewVersion);
    if (Array.isArray(record.publications)) record.publications = record.publications.map(lightPublication);
  }
  return data;
}
type Children = "all" | ReadonlySet<string>;
export function recordMut(data: LibraryData, key: string): Recording {
  const record = data.recordings.find((item) => item.id === key);
  if (!record) throw Error("Grabación no encontrada");
  return record;
}
export function recordingForWrite(data: LibraryData, recordId: string): Recording {
  const record = data.recordings.find((item) => item.id === recordId);
  if (!record) throw Error("Grabación no encontrada");
  if (record.status === "discarded") throw Error("La grabación está descartada");
  return record;
}
export function item(data: LibraryData, collection: string, itemId: string): Record<string, Json> {
  const found = catalog(data, collection).find((entry) => isObject(entry) && entry.id === itemId);
  if (!found) throw Error(`No existe ${itemId} en ${collection}`);
  return clone(found) as Record<string, Json>;
}
export function audio(data: LibraryData, root: string, recordId: string): string {
  const record = data.recordings.find((item) => item.id === recordId);
  if (!record) throw Error("Grabación no encontrada");
  if (typeof record.audioPath !== "string" || !record.audioPath) throw Error("Falta audioPath");
  let canonical: string;
  try {
    canonical = realpathSync(record.audioPath);
  } catch (error) {
    throw Error(`Audio no disponible: ${(error as Error).message}`);
  }
  if (!canonical.startsWith(`${realpathSync(join(root, "audio"))}/`)) throw Error("Audio fuera de la biblioteca");
  return canonical;
}
function updateRecording(record: Recording, params: Json) {
  if (!isObject(params)) throw Error("Actualización de grabación inválida");
  const update: Record<string, Json> = {};
  for (const key of ["title", "status", "error", "duration", "recipeId", "createdAt"]) if (key in params) update[key] = params[key] as Json;
  const parsed = readRecording({ id: record.id, status: record.status, ...update }) as Record<string, unknown>;
  const check = (key: string, ok: boolean) => {
    if (!ok) throw Error("Actualización de grabación inválida");
  };
  for (const key of ["title", "error", "recipeId", "createdAt"]) if (key in update) check(key, update[key] === null || typeof update[key] === "string");
  if ("duration" in update) check("duration", update.duration === null || typeof update.duration === "number");
  if ("status" in update) {
    if (update.status === null) throw Error("Estado no válido");
    check("status", typeof update.status === "string");
  }
  for (const key of ["title", "error", "duration", "recipeId", "createdAt"] as const) if (key in update) (record as Record<string, unknown>)[key] = parsed[key];
  if ("status" in update) record.status = parsed.status as Recording["status"];
}
function createVersion(params: Record<string, Json>, transcript: Transcript, hasVoices: boolean): Version {
  const options = readVersion({ id: "x", recipeId: params.recipeId, digest: params.digest, data: params.data, inputs: params.inputs });
  const version: Version = { id: newId(), createdAt: now(), backend: typeof params.backend === "string" ? params.backend : "local", transcript, hasVoices };
  for (const key of ["recipeId", "digest", "data", "inputs"] as const) if (key in params) (version as Record<string, unknown>)[key] = options[key] ?? null;
  return version;
}
function appendVersion(record: Recording, version: Version) {
  record.currentVersionId = version.id;
  const duration = version.transcript?.duration;
  if (typeof duration === "number") record.duration = duration;
  if (!Array.isArray(record.versions)) throw Error("Versiones inválidas");
  record.versions.push(version);
}
function collectionName(p: Json): string {
  const collection = text(p, "collection");
  if (!["accounts", "resolvers", "recipes", "destinations"].includes(collection)) throw Error("Colección desconocida");
  return collection;
}
function pruneRecipes(data: LibraryData, key: string) {
  const recipes = data.recipes;
  if (!Array.isArray(recipes)) throw Error("Recetas inválidas");
  for (const recipe of recipes) if (isObject(recipe) && recipe.kind === "form") recipe.values = prune(recipe.values ?? null, key);
}
export function memoryKey(data: LibraryData, recordingId: string, versionId: string, fingerprint: string): string {
  if (!fingerprint) throw Error("Falta la huella de memoria");
  const record = recordingForWrite(data, recordingId);
  if (!(record.versions ?? []).some((version) => version.id === versionId)) throw Error("La versión no pertenece a la grabación");
  return JSON.stringify([recordingId, versionId, fingerprint]);
}
export function markCredentials(root: string, value: Record<string, Json>) {
  for (const key of ["accounts", "resolvers"]) {
    const items = value[key];
    if (!Array.isArray(items)) continue;
    for (const entry of items) {
      if (!isObject(entry)) continue;
      let has = false;
      try {
        has = statSync(credentialPath(root, String(entry.id ?? ""))).isFile();
      } catch {
        has = false;
      }
      entry.hasCredential = has;
    }
  }
}
export function library(data: LibraryData, root: string): Record<string, Json> {
  const value = typedLibrary(data);
  value.settings = redactedSettings(value.settings);
  if (isObject(value.settings)) delete value.settings.projectOntologies;
  value.dataPath = root;
  markCredentials(root, value);
  return value;
}
async function runtimeContext(data: LibraryData, root: string, store: Store, recordingId?: string): Promise<Record<string, Json>> {
  const recordings: Json[] = [];
  if (recordingId !== undefined) {
    const original = readRecording(await store.recording(recordingId));
    const audioPath = typeof original.audioPath === "string" && original.audioPath ? "available" : null;
    recordings.push({
      id: original.id,
      title: original.title ?? null,
      createdAt: original.createdAt ?? null,
      source: `urn:escriba:recording:${recordingId}`,
      audioPath,
      audioHash: original.audioHash ?? null,
      duration: original.duration ?? null,
      status: original.status,
      error: original.error ?? null,
      recipeId: original.recipeId ?? null,
      currentVersionId: original.currentVersionId ?? null,
      versions: (original.versions ?? null) as Json,
      publications: (original.publications ?? null) as Json,
      accountEffectPending: (original as Record<string, unknown>).accountEffectPending === true,
    });
  }
  const accounts = clone(data.accounts);
  if (Array.isArray(accounts))
    for (const account of accounts)
      if (isObject(account) && typeof account.folder === "string") account.folder = `urn:escriba:folder:${createHash("sha256").update(account.folder).digest("hex")}`;
  const settings = data.settings;
  const value: Record<string, Json> = {
    recordings,
    settings: { defaultRecipeId: settings.defaultRecipeId ?? null, language: settings.language ?? null, whisperModel: settings.whisperModel ?? null },
    resolvers: clone(data.resolvers),
    recipes: clone(data.recipes),
    accounts,
    destinations: clone(data.destinations),
    providers: clone(data.providers),
  };
  markCredentials(root, value);
  return value;
}
