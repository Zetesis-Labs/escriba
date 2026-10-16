import { install, type SqlValidator } from "./catalog";
import * as jobs from "./jobs";
import type { Json } from "./json";
import type { LibraryData } from "./model";
import type { CoreChange, LogQuery } from "./persistence";
import { Store, type StoreOptions } from "./store";
import type { StagedAudio } from "./audio";
import type { CombinedRecord } from "../../core/combine";
import type { KnownVoice, SpeakerVoice } from "./voices";

const CLOSED = "La biblioteca está cerrada";
interface Published {
  index: LibraryData;
  activeJobs: Json[];
}

export class Library {
  private queue: Promise<unknown> = Promise.resolve();
  private published: Published;
  private closing = false;
  private readonly listeners = new Set<() => void>();

  private constructor(private readonly store: Store, published: Published) {
    this.published = published;
  }
  static async open(root: string, options: StoreOptions = {}): Promise<Library> {
    const store = await Store.open(root, options);
    return new Library(store, await publication(store));
  }
  static async fromStore(store: Store): Promise<Library> {
    return new Library(store, await publication(store));
  }
  get root() {
    return this.store.root;
  }
  index(): LibraryData {
    return this.published.index;
  }
  activeJobs(): Json[] {
    return this.published.activeJobs;
  }
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  libraryView(): Record<string, Json> {
    return this.store.library();
  }
  settingsJson(): Json {
    return this.store.settingsJson();
  }
  watchedFolderBookmarks() {
    return this.store.watchedFolderBookmarks();
  }
  async close() {
    this.closing = true;
    await this.queue.catch(() => undefined);
    await this.store.close();
  }
  private order<T>(operation: (store: Store) => Promise<T>): Promise<T> {
    if (this.closing) return Promise.reject(Error(CLOSED));
    const run = this.queue.then(
      () => this.serve(operation),
      () => this.serve(operation),
    );
    this.queue = run.catch(() => undefined);
    return run;
  }
  private async serve<T>(operation: (store: Store) => Promise<T>): Promise<T> {
    let result: T;
    try {
      result = await operation(this.store);
    } catch (error) {
      await this.republish();
      throw error;
    }
    await this.republish();
    return result;
  }
  private async republish() {
    try {
      this.published = await publication(this.store);
    } catch (error) {
      throw Error(`La biblioteca guardó el cambio pero no pudo leer los trabajos activos: ${(error as Error).message}`);
    }
    for (const listener of this.listeners) listener();
  }
  withStore<T>(operation: (store: Store) => Promise<T>): Promise<T> {
    return this.order(operation);
  }
  log(params: Json): void {
    if (this.closing) throw Error(CLOSED);
    void this.order((store) => store.appendLog(params)).catch((error) => {
      console.error(`${JSON.stringify(params)}; no se pudo guardar en el registro: ${(error as Error).message}`);
    });
  }
  snapshot() {
    return this.store.snapshot();
  }
  recording(id: string) {
    return this.store.recording(id);
  }
  runtimeContext(recordingId?: string) {
    return this.store.runtimeContext(recordingId);
  }
  logList(params: Json) {
    return this.store.logList(params);
  }
  memoryRecall(recordingId: string, fingerprint: string) {
    return this.store.memoryRecall(recordingId, fingerprint);
  }
  traceList(recordingId?: string) {
    return this.store.traceList(recordingId);
  }
  people() {
    return this.store.people();
  }
  knownVoices(): Promise<KnownVoice[]> {
    return this.store.knownVoices();
  }
  knowledgeChange(): Promise<CoreChange | undefined> {
    return this.store.knowledgeChange();
  }
  knowledgeChanges(limit: number): Promise<CoreChange[]> {
    return this.store.knowledgeChanges(limit);
  }
  credential(key: string) {
    return this.store.credential(key);
  }
  audio(recordingId: string) {
    return this.store.audio(recordingId);
  }
  item(collection: string, id: string) {
    return this.store.item(collection, id);
  }
  jobsFor(recordingId: string) {
    return this.store.jobsFor(recordingId);
  }
  logQuery(query: LogQuery) {
    return this.store.database.logList(query);
  }
  mutate(method: string, params: Json): Promise<Json> {
    if (method === "log") return this.order(async (store) => { await store.appendLog(params); return null; });
    return this.order((store) => store.mutate(method, params));
  }
  removeAudio(params: Json, busy: (store: Store, recordingId: string) => Promise<boolean>): Promise<Json> {
    return this.order(async (store) => {
      const id = typeof params === "object" && params && !Array.isArray(params) && typeof params.id === "string" ? params.id : "";
      if (!id) throw Error("Falta id");
      if (await busy(store, id)) throw Error("Cancela el trabajo antes de quitar su audio");
      return store.mutate("recording_remove_audio", params);
    });
  }
  removeVersions(method: "version_delete" | "version_keep_only", params: Json): Promise<Json> {
    return this.order(async (store) => {
      const id = typeof params === "object" && params && !Array.isArray(params) && typeof params.recordingId === "string" ? params.recordingId : "";
      if (!id) throw Error("Falta recordingId");
      if (await jobs.busy(store.database, id)) throw Error("Espera a que acabe el trabajo de esta nota o cancélalo antes de borrar versiones");
      return store.mutate(method, params);
    });
  }
  importStaged(staged: StagedAudio, source: string, recipeId?: string) {
    return this.order((store) => store.importStaged(staged, source, recipeId));
  }
  importRecorded(staged: StagedAudio, source: string, recipeId: string | undefined, update: Json) {
    return this.order(async (store) => {
      const record = await store.importStaged(staged, source, recipeId);
      const change = { ...(update as Record<string, Json>), id: (record as Record<string, Json>).id as Json };
      return store.mutate("recording_update", change);
    });
  }
  combine(staged: StagedAudio, combined: CombinedRecord, discard: readonly string[]) {
    return this.order(async (store) => {
      for (const id of discard) if (await jobs.busy(store.database, id)) throw Error("Espera a que acabe el trabajo de esa nota o cancélalo antes de combinar");
      return store.combine(staged, combined, discard);
    });
  }
  importWatched(staged: StagedAudio, source: string, title: string, startedAt: Date, sourceKey: string) {
    return this.order((store) => store.importStagedWithMetadata(staged, source, title, startedAt, sourceKey));
  }
  removeConnector(id: string) {
    return this.order((store) => store.removeConnector(id));
  }
  saveConnector(account: Json, destination: Json) {
    return this.order((store) => store.saveConnector(account, destination));
  }
  setPersonColor(name: string, color: string) {
    return this.order((store) => store.setPersonColor(name, color));
  }
  renamePerson(name: string, newName: string) {
    return this.order((store) => store.renamePerson(name, newName));
  }
  removePerson(name: string) {
    return this.order((store) => store.removePerson(name));
  }
  removePersonVoice(id: string) {
    return this.order((store) => store.removePersonVoice(id));
  }
  addPersonVoice(name: string, voice: SpeakerVoice, source: string) {
    return this.order((store) => store.addPersonVoice(name, voice, source));
  }
  memoryKeep(recordingId: string, fingerprint: string, value: Json) {
    return this.order((store) => store.memoryKeep(recordingId, fingerprint, value));
  }
  traceSave(trace: Json) {
    return this.order((store) => store.traceSave(trace));
  }
  recognizeTranscription(recordingId: string, transcript: Json) {
    return this.order((store) => store.recognizeTranscription(recordingId, transcript));
  }
  authorizeWatchedFolder(folderId: string | undefined, path: string, name: string | undefined, style: string, bookmark: number[]) {
    return this.order((store) => store.authorizeWatchedFolder(folderId, path, name, style, bookmark));
  }
  refreshWatchedFolderBookmark(folderId: string, previous: number[], resolved: string, replacement?: number[]) {
    return this.order((store) => store.refreshWatchedFolderBookmark(folderId, previous, resolved, replacement));
  }
  seedVoiceMemos(root: string) {
    return this.order((store) => store.seedVoiceMemos(root));
  }
  install(pkg: Json, validateSql?: SqlValidator) {
    return this.order((store) => install(store, pkg, validateSql));
  }
  knowledgePrepare(epoch: string) {
    return this.order((store) => store.knowledgePrepare(epoch));
  }
  knowledgeAck(key: string, revision: string) {
    return this.order((store) => store.knowledgeAck(key, revision));
  }
  job(id: string) {
    return jobs.find(this.store.database, id);
  }
  jobSteps(id: string) {
    return jobs.steps(this.store.database, id);
  }
  jobHistory(query: jobs.HistoryQuery) {
    return jobs.history(this.store.database, query);
  }
  busy(recordingId: string) {
    return jobs.busy(this.store.database, recordingId);
  }
  recoverJobs() {
    return this.order((store) => jobs.recover(store));
  }
  enqueueJob(operation: string, args: Json, automatic: boolean) {
    return this.order((store) => jobs.enqueue(store, operation, args, automatic));
  }
  enqueueAutomaticJobs() {
    return this.order((store) => jobs.automatic(store));
  }
  claimJob(lane: jobs.Lane, now: number) {
    return this.order((store) => jobs.claim(store, lane, now));
  }
  finishJob(id: string, result: jobs.JobResult) {
    return this.order((store) => jobs.finish(store, id, result));
  }
  jobStages(value: Json) {
    return this.order((store) => jobs.stages(store, value));
  }
  cancelJobs(recordingId: string) {
    return this.order((store) => jobs.cancel(store, recordingId));
  }
  relaunchJob(id: string) {
    return this.order((store) => jobs.relaunch(store, id));
  }
  purgeJobs(now: number) {
    return this.order((store) => jobs.purge(store, now));
  }
}
async function publication(store: Store): Promise<Published> {
  return { index: store.data, activeJobs: await jobs.visible(store.database) };
}
