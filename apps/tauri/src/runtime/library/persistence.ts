import { canonical, isObject, newId, now, text, type Json } from "./json";
import { changes, preview, type Children, type RowOp, type RowWrite, type Table } from "./changes";
import { readLibraryData, readRecording, readVersion } from "./model";
import { lightPublication, lightVersion } from "./projection";
import { closeDatabase, literal, openDatabase, rowByKey, rows, rowsForParent, run, Transaction, type Database, type Row } from "./surreal";
import type { KnownVoice, SpeakerVoice } from "./voices";

export const LOG_RETAINED = 3000;
const TRIM_EVERY = 64;
let appended = 0;

export interface WriteScope {
  fullRecordings: Set<string>;
  recipeAliases: Map<string, string>;
  draftChange?: [string, Json | null];
  draftReceipt?: [string, string, Json];
}
export const scope = (partial: Partial<WriteScope> = {}): WriteScope => ({
  fullRecordings: partial.fullRecordings ?? new Set(),
  recipeAliases: partial.recipeAliases ?? new Map(),
  ...(partial.draftChange ? { draftChange: partial.draftChange } : {}),
  ...(partial.draftReceipt ? { draftReceipt: partial.draftReceipt } : {}),
});
export interface Teaching {
  person: string;
  voices: SpeakerVoice[];
  source: string;
  existingOnly: boolean;
}
export interface AudioDeletion {
  id: string;
  path: string;
  device: number;
  inode: number;
}
export const audioDeletion = (path: string, device: number, inode: number): AudioDeletion => ({ id: newId(), path, device, inode });
export interface LibraryWrite {
  ops: RowOp[];
  recipeAliases?: Map<string, string>;
  draftChange?: [string, Json | null];
  draftReceipt?: [string, string, Json];
  audioDeletions?: AudioDeletion[];
  versionVoices?: [string, SpeakerVoice[]];
  teaching?: Teaching;
  logs?: Json[];
}
export const scopedWrite = (scope: WriteScope, ops: RowOp[]): LibraryWrite => ({
  ops,
  recipeAliases: scope.recipeAliases,
  ...(scope.draftChange ? { draftChange: scope.draftChange } : {}),
  ...(scope.draftReceipt ? { draftReceipt: scope.draftReceipt } : {}),
});
interface PersonRecord {
  id: string;
  name: string;
  color?: string;
  created_at: string;
}
interface PersonVoiceRecord {
  id: string;
  person_id: string;
  model: string;
  embedding: number[];
  source: string;
  added_at: string;
}
interface VersionVoiceRecord {
  id: string;
  version_id: string;
  speaker: string;
  model: string;
  embedding: number[];
}
export interface CoreChange {
  key: string;
  revision: string;
  kind: string;
  id: string;
  value: Json | null;
}
export interface LogQuery {
  recordingId?: string;
  before?: string;
  limit?: number;
}
const TABLES = [
  "meta", "recording", "version", "publication", "version_preview", "publication_preview", "account", "resolver",
  "recipe", "destination", "provider", "log", "setting", "job", "memory", "trace", "person", "person_voice", "voice",
  "audio_deletion", "note_draft", "note_draft_receipt",
];
const PARENT_INDEXED = ["version", "publication", "version_preview", "publication_preview", "job", "memory", "trace", "person_voice", "voice", "note_draft", "note_draft_receipt"];
const OBJECT_PAYLOAD = TABLES.filter((table) => !["meta", "setting"].includes(table));
const TABLE_NAMES = ["recording", "version", "publication", "account", "resolver", "recipe", "destination", "provider", "log", "setting"];
const CATALOG_FIELDS: Record<string, string> = { recording: "recordings", account: "accounts", resolver: "resolvers", recipe: "recipes", destination: "destinations", provider: "providers" };

export function parseLogQuery(value: unknown): LogQuery {
  if (!isObject(value)) throw Error("Consulta del registro inválida");
  const query: LogQuery = {};
  for (const [key, item] of Object.entries(value)) {
    if (item === null || item === undefined) continue;
    if (key === "recordingId" && typeof item === "string") query.recordingId = item;
    else if (key === "before" && typeof item === "string") query.before = item;
    else if (key === "limit" && typeof item === "number" && Number.isInteger(item) && item >= 0) query.limit = item;
    else throw Error("Consulta del registro inválida");
  }
  return query;
}
function metaHas(metadata: Row[], key: string, value: string) {
  return metadata.some((row) => row.key === key && row.payload === value);
}
function previewFor(table: string, payload: Json): Json {
  if (table === "version") return lightVersion(payload) as Json;
  if (table === "publication") {
    if (!isObject(payload) || typeof payload.destinationId !== "string") throw Error("Recibo guardado inválido");
    return lightPublication(payload);
  }
  throw Error("Tabla sin proyección");
}
function orderRecordings(items: Row[]) {
  const created = (row: Row) => (isObject(row.payload) && typeof row.payload.createdAt === "string" ? row.payload.createdAt : undefined);
  items.sort((left, right) => {
    const a = created(left);
    const b = created(right);
    if (a !== b) {
      if (a === undefined) return -1;
      if (b === undefined) return 1;
      return a < b ? 1 : -1;
    }
    return left.key < right.key ? -1 : left.key > right.key ? 1 : 0;
  });
}
const payloadField = (payload: Json, key: string) => (isObject(payload) && key in payload ? payload[key] : null);
function upsertRow(tx: Transaction, row: RowWrite) {
  const payload = row.payload;
  tx.add(
    `UPSERT type::record(${tx.bind(row.table)}, ${tx.bind(row.key)}) SET key = ${tx.bind(row.key)}, parent = ${tx.bind(row.parent)}, position = ${tx.bind(row.position)}, payload = ${tx.bind(payload)}, title = ${tx.bind(payloadField(payload, "title"))}, status = ${tx.bind(payloadField(payload, "status"))}, createdAt = ${tx.bind(payloadField(payload, "createdAt"))}, backend = ${tx.bind(payloadField(payload, "backend"))}, state = ${tx.bind(payloadField(payload, "state"))}, recordingId = ${tx.bind(payloadField(payload, "recordingId"))}`,
  );
  const previewTable = preview(row.table);
  if (previewTable)
    tx.add(
      `UPSERT type::record(${tx.bind(previewTable)}, ${tx.bind(row.key)}) SET key = ${tx.bind(row.key)}, parent = ${tx.bind(row.parent)}, position = ${tx.bind(row.position)}, payload = ${tx.bind(previewFor(row.table, payload))}`,
    );
  if (row.table === "recording" && isObject(payload) && payload.status === "discarded") deleteRecordingChildren(tx, row.key);
}
function deleteRecordingChildren(tx: Transaction, key: string) {
  const parent = literal(key);
  tx.add(`DELETE voice WHERE parent IN (SELECT VALUE payload.id FROM version_preview WHERE parent = ${parent})`);
  for (const child of ["version", "publication", "version_preview", "publication_preview", "memory", "trace", "job", "note_draft", "note_draft_receipt"])
    tx.add(`DELETE ${child} WHERE parent = ${parent}`);
}
function deleteRow(tx: Transaction, table: Table, key: string, id: string) {
  tx.add(`DELETE type::record(${tx.bind(table)}, ${tx.bind(key)})`);
  if (table === "recording") deleteRecordingChildren(tx, key);
  else if (table === "version") tx.add(`DELETE voice WHERE parent = ${literal(id)}`);
  const previewTable = preview(table);
  if (previewTable) tx.add(`DELETE type::record(${tx.bind(previewTable)}, ${tx.bind(key)})`);
}
function applyAliases(tx: Transaction, aliases: Map<string, string>) {
  const pairs = [...aliases].filter(([old, next]) => old !== next);
  if (!pairs.length) return;
  const names = pairs.map(([old], index) => {
    const name = `alias${index}`;
    tx.add(`LET $${name} = (SELECT VALUE key FROM version_preview WHERE payload.recipeId = ${tx.bind(old)})`);
    return name;
  });
  pairs.forEach(([, next], index) => {
    for (const table of ["version", "version_preview"])
      tx.add(`UPDATE ${table} SET payload.recipeId = ${tx.bind(next)} WHERE key IN $${names[index]}`);
  });
}
function insertLog(tx: Transaction, entry: Json) {
  if (!isObject(entry)) throw Error("Línea de registro incompleta");
  const key = typeof entry.id === "string" && entry.id ? entry.id : undefined;
  if (!key) throw Error("Línea de registro sin identidad");
  if (typeof entry.at !== "string" || typeof entry.message !== "string") throw Error("Línea de registro incompleta");
  const parent = typeof entry.recordingId === "string" ? entry.recordingId : "";
  tx.add(`UPSERT type::record('log', ${tx.bind(key)}) SET key = ${tx.bind(key)}, parent = ${tx.bind(parent)}, position = 0, payload = ${tx.bind(entry)}`);
}

export class Persistence {
  private constructor(readonly db: Database, private readonly path: string) {}

  static async open(path: string): Promise<Persistence> {
    const db = await openDatabase(path, "escriba", "library");
    try {
      await connect(db);
    } catch (error) {
      await closeDatabase(db, path).catch(() => undefined);
      throw error;
    }
    return new Persistence(db, path);
  }
  async close() {
    await closeDatabase(this.db, this.path);
  }
  knowledgePrepare(epoch: string) {
    return knowledgePrepare(this.db, epoch);
  }
  knowledgeChange() {
    return knowledgeChange(this.db);
  }
  knowledgeAck(key: string, revision: string) {
    return knowledgeAck(this.db, key, revision);
  }
  load() {
    return load(this.db);
  }
  loadIndex() {
    return loadIndex(this.db);
  }
  async draftRead(key: string, receipt: boolean): Promise<Json | undefined> {
    return (await rowByKey(this.db, receipt ? "note_draft_receipt" : "note_draft", key))?.payload;
  }
  recording(id: string) {
    return recording(this.db, id);
  }
  write(write: LibraryWrite) {
    return apply(this.db, write);
  }
  async appendLog(entry: Json) {
    const tx = new Transaction();
    insertLog(tx, entry);
    await tx.commit(this.db);
    if (appended++ % TRIM_EVERY === 0) await trimLogs(this.db);
  }
  async logList(query: LogQuery): Promise<Json[]> {
    const limit = Math.min(Math.max(query.limit ?? LOG_RETAINED, 1), LOG_RETAINED);
    const vars: Record<string, unknown> = { limit };
    if (query.recordingId !== undefined) vars.recording = query.recordingId;
    if (query.before !== undefined) vars.before = query.before;
    const [found] = await run<[{ payload: Json }[]]>(
      this.db,
      "SELECT payload, payload.at AS at FROM log WHERE ($recording = NONE OR payload.recordingId = $recording) AND ($before = NONE OR payload.at < $before) ORDER BY at DESC LIMIT $limit",
      vars,
    );
    return (found ?? []).map((row) => row.payload);
  }
  async save(before: unknown, after: unknown) {
    await this.write({ ops: changes(readLibraryData(before), readLibraryData(after), "all") });
  }
  async saveScoped(before: unknown, after: unknown, scope: WriteScope) {
    await this.write(scopedWrite(scope, changes(readLibraryData(before), readLibraryData(after), scope.fullRecordings)));
  }
  async pendingAudioDeletions(): Promise<AudioDeletion[]> {
    return (await rows(this.db, "audio_deletion")).map((row) => {
      const deletion = row.payload;
      if (!isObject(deletion) || deletion.id !== row.key || typeof deletion.path !== "string" || typeof deletion.device !== "number" || typeof deletion.inode !== "number")
        throw Error("Cola de borrado de audio incoherente");
      return { id: deletion.id as string, path: deletion.path, device: deletion.device, inode: deletion.inode };
    });
  }
  async completeAudioDeletion(id: string) {
    await run(this.db, "DELETE type::record('audio_deletion', $key)", { key: id });
  }
  async jobs(): Promise<Json[]> {
    return (await rows(this.db, "job")).map((row) => row.payload);
  }
  async jobsActive(): Promise<Json[]> {
    const results = await run<[Json[], Json[], Json[]]>(
      this.db,
      "SELECT VALUE payload FROM job WHERE state = 'queued'; SELECT VALUE payload FROM job WHERE state = 'running'; SELECT VALUE payload FROM job WHERE state = 'retry'",
    );
    return results.flatMap((items) => items ?? []);
  }
  async jobsFinished(): Promise<Json[]> {
    const [found] = await run<[Json[]]>(this.db, "SELECT VALUE payload FROM job WHERE state IN ['succeeded', 'failed', 'cancelled']");
    return found ?? [];
  }
  async jobsFor(recording: string): Promise<Json[]> {
    return (await rowsForParent(this.db, "job", recording)).map((row) => row.payload);
  }
  async job(id: string): Promise<Json | undefined> {
    return (await rowByKey(this.db, "job", id))?.payload;
  }
  async saveJob(job: Json) {
    if (!isObject(job)) throw Error("Job sin ID");
    const key = typeof job.id === "string" && job.id ? job.id : undefined;
    if (!key) throw Error("Job sin ID");
    const parent = typeof job.recordingId === "string" && job.recordingId ? job.recordingId : undefined;
    if (!parent) throw Error("Job sin grabación");
    if (typeof job.state !== "string" || !job.state) throw Error("Job sin estado");
    await run(
      this.db,
      "UPSERT type::record('job', $key) SET key = $key, parent = $parent, position = 0, payload = $payload, recordingId = $parent, state = $state",
      { key, parent, payload: job, state: job.state },
    );
  }
  async removeJobs(ids: string[]) {
    await run(this.db, "DELETE job WHERE key IN $keys AND state IN ['succeeded', 'failed', 'cancelled']", { keys: ids });
  }
  async removeJob(id: string) {
    await run(this.db, "DELETE type::record('job', $key)", { key: id });
  }
  async recall(key: string): Promise<Json | undefined> {
    return (await rowByKey(this.db, "memory", key))?.payload;
  }
  async keep(key: string, parent: string, value: Json) {
    await run(this.db, "UPSERT type::record('memory', $key) SET key = $key, parent = $parent, position = 0, payload = $payload", { key, parent, payload: value });
  }
  async traceSave(trace: Json) {
    const key = text(trace, "id");
    const parent = text(trace, "recordingId");
    await run(this.db, "UPSERT type::record('trace', $key) SET key = $key, parent = $parent, position = 0, payload = $payload", { key, parent, payload: trace });
  }
  async traceList(recordingId?: string): Promise<Json[]> {
    const values = (await rows(this.db, "trace")).filter((row) => recordingId === undefined || row.parent === recordingId).map((row) => row.payload);
    const started = (value: Json) => (isObject(value) && typeof value.startedAt === "string" ? value.startedAt : "");
    values.sort((a, b) => (started(b) < started(a) ? -1 : started(b) > started(a) ? 1 : 0));
    return values;
  }
  async people(): Promise<Json[]> {
    const people = (await personRecords(this.db)).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    const voices = await personVoiceRecords(this.db);
    return people.flatMap((person) => {
      const own = voices.filter((voice) => voice.person_id === person.id).map((voice) => ({ id: voice.id, model: voice.model, source: voice.source, addedAt: voice.added_at }));
      if (!own.length) return [];
      const value: Record<string, Json> = { id: person.id, name: person.name, voices: own };
      if (person.color !== undefined) value.color = person.color;
      return [value];
    });
  }
  async knownVoices(): Promise<KnownVoice[]> {
    const people = await personRecords(this.db);
    const voices = await personVoiceRecords(this.db);
    return voices.flatMap((voice) => {
      const person = people.find((item) => item.id === voice.person_id);
      return person ? [{ person: person.name, personId: person.id, model: voice.model, embedding: voice.embedding }] : [];
    });
  }
  async addPersonVoice(name: string, voice: SpeakerVoice, source: string) {
    if (!name.trim() || !voice.model || !voice.embedding.length || voice.embedding.some((value) => !Number.isFinite(value)))
      throw Error("Huella de voz inválida");
    const person = (await personRecords(this.db)).find((item) => item.name === name) ?? { id: newId(), name, created_at: now() };
    const fresh = !(await rows(this.db, "person")).some((row) => row.key === person.id);
    const position = Math.max(-1, ...(await rows(this.db, "person_voice")).map((row) => row.position)) + 1;
    const record: PersonVoiceRecord = { id: newId(), person_id: person.id, model: voice.model, embedding: voice.embedding, source, added_at: now() };
    const tx = new Transaction();
    if (fresh) tx.add(`CREATE type::record('person', ${tx.bind(person.id)}) SET key = ${tx.bind(person.id)}, parent = '', position = 0, payload = ${tx.bind(person)}`);
    tx.add(`CREATE type::record('person_voice', ${tx.bind(record.id)}) SET key = ${tx.bind(record.id)}, parent = ${tx.bind(person.id)}, position = ${tx.bind(position)}, payload = ${tx.bind(record)}`);
    await tx.commit(this.db);
  }
  async setPersonColor(name: string, color: string) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(color)) throw Error("El color debe tener formato #RRGGBB");
    const person = (await personRecords(this.db)).find((item) => item.name === name);
    if (!person) throw Error("Persona no encontrada");
    await run(this.db, "UPDATE type::record('person', $key) SET payload = $payload", { key: person.id, payload: { ...person, color } });
  }
  async renamePerson(name: string, newName: string) {
    if (name === newName) return;
    if (!newName.trim()) throw Error("Escribe un nombre");
    const people = await personRecords(this.db);
    const source = people.find((item) => item.name === name);
    if (!source) throw Error("Persona no encontrada");
    const target = people.find((item) => item.name === newName);
    const sourceVoices = (await rows(this.db, "person_voice")).filter((row) => row.parent === source.id);
    const tx = new Transaction();
    if (target) {
      if (target.color === undefined && source.color !== undefined)
        tx.add(`UPDATE type::record('person', ${tx.bind(target.id)}) SET payload = ${tx.bind({ ...target, color: source.color })}`);
      for (const row of sourceVoices) {
        if (!isObject(row.payload)) throw Error("Huella guardada inválida");
        tx.add(`UPDATE type::record('person_voice', ${tx.bind(row.key)}) SET parent = ${tx.bind(target.id)}, payload = ${tx.bind({ ...row.payload, person_id: target.id })}`);
      }
      tx.add(`DELETE type::record('person', ${tx.bind(source.id)})`);
    } else tx.add(`UPDATE type::record('person', ${tx.bind(source.id)}) SET payload = ${tx.bind({ ...source, name: newName })}`);
    await tx.commit(this.db);
  }
  async removePersonVoice(id: string) {
    const voices = await rows(this.db, "person_voice");
    const voice = voices.find((row) => row.key === id);
    if (!voice) throw Error("Huella no encontrada");
    const last = !voices.some((row) => row.parent === voice.parent && row.key !== id);
    const tx = new Transaction();
    tx.add(`DELETE type::record('person_voice', ${tx.bind(id)})`);
    if (last) tx.add(`DELETE type::record('person', ${tx.bind(voice.parent)})`);
    await tx.commit(this.db);
  }
  async removePerson(name: string) {
    const person = (await personRecords(this.db)).find((item) => item.name === name);
    if (!person) return;
    const tx = new Transaction();
    tx.add(`DELETE type::table('person_voice') WHERE parent = ${tx.bind(person.id)}`);
    tx.add(`DELETE type::record('person', ${tx.bind(person.id)})`);
    await tx.commit(this.db);
  }
  async versionVoices(id: string): Promise<SpeakerVoice[]> {
    const items = await rowsForParent(this.db, "voice", id);
    items.sort((a, b) => a.position - b.position);
    return items.map((row) => {
      const voice = row.payload as Partial<VersionVoiceRecord> | null;
      if (!isObject(voice) || typeof voice.speaker !== "string" || typeof voice.model !== "string" || !Array.isArray(voice.embedding))
        throw Error("Huella guardada inválida");
      return { speaker: voice.speaker, model: voice.model, embedding: voice.embedding as number[] };
    });
  }
  async queryTest(sql: string) {
    await run(this.db, sql);
  }
  async selectTest(sql: string): Promise<Json[]> {
    const [found] = await run<[Json[]]>(this.db, sql);
    return found ?? [];
  }
  downgradeV1Test() {
    return downgradeV1(this.db);
  }
}

async function connect(db: Database) {
  const definitions: string[] = [];
  for (const table of TABLES) {
    definitions.push(`DEFINE TABLE IF NOT EXISTS ${table} SCHEMALESS`);
    definitions.push(`DEFINE INDEX IF NOT EXISTS idx_${table}_key ON TABLE ${table} FIELDS key UNIQUE`);
    if (PARENT_INDEXED.includes(table)) definitions.push(`DEFINE INDEX IF NOT EXISTS idx_${table}_parent ON TABLE ${table} FIELDS parent`);
  }
  definitions.push("DEFINE INDEX IF NOT EXISTS idx_job_state ON TABLE job FIELDS state");
  await run(db, definitions.join("; "));
  await migrateV1(db);
  await run(db, OBJECT_PAYLOAD.map((table) => `DEFINE FIELD OVERWRITE payload ON TABLE ${table} TYPE object`).join("; "));
  await knowledgeInitialize(db);
  await trimLogs(db);
}
async function migrateV1(db: Database) {
  const metadata = await rows(db, "meta");
  if (!metaHas(metadata, "schema", "1")) return;
  const prior: [string, Row][] = [];
  for (const table of [...TABLE_NAMES, "job", "memory", "trace"]) for (const row of await rows(db, table)) prior.push([table, row]);
  const tx = new Transaction();
  for (const [table, row] of prior) {
    if (typeof row.payload !== "string") throw Error(`Esquema anterior ${table}/${row.key} inválido`);
    let payload: Json;
    try {
      payload = JSON.parse(row.payload) as Json;
    } catch (error) {
      throw Error(`Esquema anterior ${table}/${row.key} corrupto: ${(error as Error).message}`);
    }
    upsertRowPlain(tx, table, row.key, row.parent, row.position, payload);
  }
  tx.add("UPSERT meta:schema SET key = 'schema', parent = '', position = 0, payload = '2'");
  await tx.commit(db);
}
function upsertRowPlain(tx: Transaction, table: string, key: string, parent: string, position: number, payload: Json) {
  tx.add(
    `UPSERT type::record(${tx.bind(table)}, ${tx.bind(key)}) SET key = ${tx.bind(key)}, parent = ${tx.bind(parent)}, position = ${tx.bind(position)}, payload = ${tx.bind(payload)}, title = ${tx.bind(payloadField(payload, "title"))}, status = ${tx.bind(payloadField(payload, "status"))}, createdAt = ${tx.bind(payloadField(payload, "createdAt"))}, backend = ${tx.bind(payloadField(payload, "backend"))}, state = ${tx.bind(payloadField(payload, "state"))}, recordingId = ${tx.bind(payloadField(payload, "recordingId"))}`,
  );
}
async function downgradeV1(db: Database) {
  const prior: [string, Row][] = [];
  for (const table of [...TABLE_NAMES, "job", "memory", "trace"]) {
    for (const row of await rows(db, table)) prior.push([table, row]);
    if (table !== "setting") await run(db, `DEFINE FIELD OVERWRITE payload ON TABLE ${table} TYPE any`);
  }
  const tx = new Transaction();
  for (const [table, row] of prior) tx.add(`UPDATE type::record(${tx.bind(table)}, ${tx.bind(row.key)}) SET payload = ${tx.bind(JSON.stringify(row.payload))}`);
  tx.add("UPDATE meta:schema SET payload = '1'");
  await tx.commit(db);
}
async function load(db: Database): Promise<Json | undefined> {
  const metadata = await rows(db, "meta");
  if (!metaHas(metadata, "initialized", "1")) {
    for (const table of TABLE_NAMES) if ((await rows(db, table)).length) throw Error("SurrealDB contiene datos sin marca de migración completa");
    return undefined;
  }
  if (!metaHas(metadata, "schema", "2")) throw Error("Versión de esquema SurrealDB incompatible");
  const data: Record<string, Json> = { schemaVersion: 1, recordings: [], accounts: [], resolvers: [], recipes: [], destinations: [], providers: [], settings: {} };
  const children = new Map<string, { versions: [number, Json][]; publications: [number, Json][] }>();
  const entry = (parent: string) => {
    let found = children.get(parent);
    if (!found) children.set(parent, (found = { versions: [], publications: [] }));
    return found;
  };
  for (const table of TABLE_NAMES.filter((table) => table !== "log")) {
    const items = await rows(db, table);
    if (table === "recording") orderRecordings(items);
    else items.sort((a, b) => a.position - b.position);
    for (const row of items) {
      if (table === "version") entry(row.parent).versions.push([row.position, row.payload]);
      else if (table === "publication") entry(row.parent).publications.push([row.position, row.payload]);
      else if (table === "setting") (data.settings as Record<string, Json>)[row.key] = row.payload;
      else {
        const field = CATALOG_FIELDS[table];
        if (!field) throw Error(`Tabla inesperada: ${table}`);
        (data[field] as Json[]).push(row.payload);
      }
    }
  }
  for (const recording of data.recordings as Record<string, Json>[]) {
    const id = recording.id;
    if (typeof id !== "string") throw Error("Grabación sin ID");
    const own = children.get(id);
    children.delete(id);
    recording.versions = own ? own.versions.map(([, value]) => value) : [];
    recording.publications = own ? own.publications.map(([, value]) => value) : [];
  }
  if (children.size) throw Error("SurrealDB contiene versiones o recibos huérfanos");
  return data;
}
async function backfillPreviews(db: Database): Promise<boolean> {
  const metadata = await rows(db, "meta");
  if (metaHas(metadata, "preview_v1", "1") || !metaHas(metadata, "initialized", "1")) return false;
  const records = new Set((await rows(db, "recording")).map((row) => row.key));
  for (const table of ["version", "publication"]) {
    const [keys] = await run<[{ key: string; parent: string }[]]>(db, "SELECT key, parent FROM type::table($table)", { table });
    for (const child of keys ?? []) {
      if (!records.has(child.parent)) throw Error(`SurrealDB contiene ${table} huérfana`);
      const row = await rowByKey(db, table, child.key);
      if (!row) throw Error("Fila de biblioteca desaparecida");
      const previewValue = previewFor(table, row.payload);
      const idField = table === "version" ? "id" : "destinationId";
      const id = isObject(previewValue) ? previewValue[idField] : undefined;
      if (typeof id !== "string") throw Error(`${table} sin ${idField}`);
      if (row.parent !== child.parent || child.key !== JSON.stringify([child.parent, id])) throw Error(`Identidad de ${table} incoherente`);
      await run(db, "UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload", {
        table: `${table}_preview`, key: child.key, parent: child.parent, position: row.position, payload: previewValue,
      });
    }
  }
  return true;
}
async function loadIndex(db: Database): Promise<Json | undefined> {
  const metadata = await rows(db, "meta");
  if (!metaHas(metadata, "initialized", "1")) {
    for (const table of [...TABLE_NAMES, "version_preview", "publication_preview"])
      if ((await rows(db, table)).length) throw Error("SurrealDB contiene datos sin marca de migración completa");
    return undefined;
  }
  if (!metaHas(metadata, "schema", "2")) throw Error("Versión de esquema SurrealDB incompatible");
  const needsPreviewMark = await backfillPreviews(db);
  const data: Record<string, Json> = { schemaVersion: 1, recordings: [], accounts: [], resolvers: [], recipes: [], destinations: [], providers: [], settings: {} };
  const parents = new Set<string>();
  for (const table of ["recording", "account", "resolver", "recipe", "destination", "provider", "setting"]) {
    const items = await rows(db, table);
    if (table === "recording") orderRecordings(items);
    else items.sort((a, b) => a.position - b.position);
    for (const row of items) {
      if (table === "setting") {
        (data.settings as Record<string, Json>)[row.key] = row.payload;
        continue;
      }
      const field = CATALOG_FIELDS[table]!;
      let item = row.payload;
      if (table === "recording") {
        if (!isObject(item) || item.id !== row.key) throw Error("Grabación guardada inválida");
        parents.add(row.key);
        item = { ...item, versions: [], publications: [] };
      }
      (data[field] as Json[]).push(item);
    }
  }
  const children = new Map<string, { versions: [number, Json][]; publications: [number, Json][] }>();
  for (const [table, previewTable] of [["version", "version_preview"], ["publication", "publication_preview"]]) {
    for (const row of await rows(db, previewTable!)) {
      if (!parents.has(row.parent)) throw Error(`SurrealDB contiene ${table} huérfana`);
      if (!isObject(row.payload)) throw Error(`Proyección de ${table} inválida`);
      const idField = table === "version" ? "id" : "destinationId";
      const childId = row.payload[idField];
      if (typeof childId !== "string") throw Error(`Proyección de ${table} sin ${idField}`);
      if (row.key !== JSON.stringify([row.parent, childId])) throw Error(`Identidad de ${table} incoherente`);
      let found = children.get(row.parent);
      if (!found) children.set(row.parent, (found = { versions: [], publications: [] }));
      (table === "version" ? found.versions : found.publications).push([row.position, row.payload]);
    }
  }
  for (const record of data.recordings as Record<string, Json>[]) {
    const own = children.get(record.id as string);
    if (!own) continue;
    record.versions = own.versions.sort((a, b) => a[0] - b[0]).map(([, value]) => value);
    record.publications = own.publications.sort((a, b) => a[0] - b[0]).map(([, value]) => value);
  }
  readLibraryData(data);
  if (needsPreviewMark) await run(db, "UPSERT meta:preview_v1 SET key = 'preview_v1', parent = '', position = 0, payload = '1'");
  return data;
}
async function recording(db: Database, id: string): Promise<Json | undefined> {
  const row = await rowByKey(db, "recording", id);
  if (!row) return undefined;
  if (!isObject(row.payload) || row.payload.id !== id) throw Error("Grabación guardada inválida");
  const value: Record<string, Json> = { ...row.payload };
  for (const [table, field] of [["version", "versions"], ["publication", "publications"]] as const) {
    const children = (await rowsForParent(db, table, id)).sort((a, b) => a.position - b.position);
    const previews = (await rowsForParent(db, `${table}_preview`, id)).sort((a, b) => a.position - b.position);
    const idField = table === "version" ? "id" : "destinationId";
    const mismatch =
      children.length !== previews.length ||
      children.some((full, index) => {
        const previewRow = previews[index]!;
        return full.key !== previewRow.key || full.position !== previewRow.position || canonical(payloadField(full.payload, idField)) !== canonical(payloadField(previewRow.payload, idField));
      });
    if (mismatch) throw Error(`${table} y su proyección no coinciden`);
    if (value.status === "discarded") {
      if (children.length) throw Error("Lápida con versiones o recibos");
    } else value[field] = children.map((child) => child.payload);
  }
  readRecording(value);
  return value;
}
interface TeachingPlan {
  person: PersonRecord;
  fresh: boolean;
  voices: SpeakerVoice[];
  source: string;
  startPosition: number;
}
async function teachingPlan(db: Database, teaching: Teaching | undefined): Promise<TeachingPlan | undefined> {
  if (!teaching || !teaching.voices.length) return undefined;
  if (!teaching.person.trim()) throw Error("Escribe un nombre");
  const existing = (await personRecords(db)).find((person) => person.name === teaching.person);
  if (teaching.existingOnly && !existing) return undefined;
  const person = existing ?? { id: newId(), name: teaching.person, created_at: now() };
  const startPosition = Math.max(-1, ...(await rows(db, "person_voice")).map((row) => row.position)) + 1;
  return { person, fresh: !existing, voices: teaching.voices, source: teaching.source, startPosition };
}
async function apply(db: Database, write: LibraryWrite): Promise<boolean> {
  const plan = await teachingPlan(db, write.teaching);
  const tx = new Transaction();
  for (const op of write.ops) {
    if (op.kind === "upsert") upsertRow(tx, op.row);
    else deleteRow(tx, op.table, op.key, op.id);
  }
  if (write.draftChange) {
    const [key, value] = write.draftChange;
    if (value !== null) tx.add(`UPSERT type::record('note_draft', ${tx.bind(key)}) SET key = ${tx.bind(key)}, parent = ${tx.bind(key)}, position = 0, payload = ${tx.bind(value)}`);
    else tx.add(`DELETE type::record('note_draft', ${tx.bind(key)})`);
  }
  if (write.draftReceipt) {
    const [key, parent, receipt] = write.draftReceipt;
    tx.add(`CREATE type::record('note_draft_receipt', ${tx.bind(key)}) SET key = ${tx.bind(key)}, parent = ${tx.bind(parent)}, position = 0, payload = ${tx.bind(receipt)}`);
  }
  applyAliases(tx, write.recipeAliases ?? new Map());
  if (write.versionVoices) {
    const [versionId, voices] = write.versionVoices;
    voices.forEach((voice, position) => {
      const record: VersionVoiceRecord = { id: `${versionId}:${position}`, version_id: versionId, speaker: voice.speaker, model: voice.model, embedding: voice.embedding };
      tx.add(`CREATE type::record('voice', ${tx.bind(record.id)}) SET key = ${tx.bind(record.id)}, parent = ${tx.bind(versionId)}, position = ${tx.bind(position)}, payload = ${tx.bind(record)}`);
    });
  }
  if (plan) {
    if (plan.fresh) tx.add(`CREATE type::record('person', ${tx.bind(plan.person.id)}) SET key = ${tx.bind(plan.person.id)}, parent = '', position = 0, payload = ${tx.bind(plan.person)}`);
    plan.voices.forEach((voice, index) => {
      const record: PersonVoiceRecord = { id: newId(), person_id: plan.person.id, model: voice.model, embedding: voice.embedding, source: plan.source, added_at: now() };
      tx.add(`CREATE type::record('person_voice', ${tx.bind(record.id)}) SET key = ${tx.bind(record.id)}, parent = ${tx.bind(plan.person.id)}, position = ${tx.bind(plan.startPosition + index)}, payload = ${tx.bind(record)}`);
    });
  }
  for (const deletion of write.audioDeletions ?? [])
    tx.add(`UPSERT type::record('audio_deletion', ${tx.bind(deletion.id)}) SET key = ${tx.bind(deletion.id)}, parent = '', position = 0, payload = ${tx.bind(deletion)}`);
  for (const entry of write.logs ?? []) insertLog(tx, entry);
  tx.add("UPSERT meta:initialized SET key = 'initialized', parent = '', position = 0, payload = '1'");
  tx.add("UPSERT meta:schema SET key = 'schema', parent = '', position = 0, payload = '2'");
  await tx.commit(db);
  return plan !== undefined;
}
async function trimLogs(db: Database) {
  const [found] = await run<[{ at?: string }[]]>(db, "SELECT payload.at AS at FROM log ORDER BY at DESC LIMIT 1 START $retained", { retained: LOG_RETAINED });
  const cut = found?.[0]?.at;
  if (typeof cut !== "string") return;
  await run(db, "DELETE log WHERE payload.at <= $cut", { cut });
}
async function personRecords(db: Database): Promise<PersonRecord[]> {
  return (await rows(db, "person")).map((row) => {
    const person = row.payload;
    if (!isObject(person) || typeof person.id !== "string" || typeof person.name !== "string" || typeof person.created_at !== "string") throw Error("Persona guardada inválida");
    const record: PersonRecord = { id: person.id, name: person.name, created_at: person.created_at };
    if (typeof person.color === "string") record.color = person.color;
    return record;
  });
}
async function personVoiceRecords(db: Database): Promise<PersonVoiceRecord[]> {
  const items = (await rows(db, "person_voice")).sort((a, b) => a.position - b.position);
  return items.map((row) => {
    const voice = row.payload;
    if (!isObject(voice) || typeof voice.id !== "string" || typeof voice.person_id !== "string" || typeof voice.model !== "string" || !Array.isArray(voice.embedding) || typeof voice.source !== "string" || typeof voice.added_at !== "string")
      throw Error("Huella guardada inválida");
    return { id: voice.id, person_id: voice.person_id, model: voice.model, embedding: voice.embedding as number[], source: voice.source, added_at: voice.added_at };
  });
}

async function knowledgeInitialize(db: Database) {
  await run(db, "DEFINE TABLE IF NOT EXISTS knowledge_dirty SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS knowledge_meta SCHEMALESS PERMISSIONS NONE");
  for (const [table, kind, owner] of [["recording", "recording", "key"], ["version", "recording", "parent"], ["person", "person", "key"]])
    await run(
      db,
      `DEFINE EVENT OVERWRITE knowledge_changed ON TABLE ${table} WHEN $before != $after THEN { LET $entity = IF $event = 'DELETE' { $before.${owner} } ELSE { $after.${owner} }; LET $key = '${kind}:' + $entity; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = '${kind}', entity_id = $entity, revision = type::string(rand::uuid()); }`,
    );
  await run(
    db,
    "BEGIN; IF !record::exists(knowledge_meta:backfill_v1) { FOR $row IN (SELECT key FROM recording) { LET $key = 'recording:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'recording', entity_id = $row.key, revision = type::string(rand::uuid()); }; FOR $row IN (SELECT key FROM person) { LET $key = 'person:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'person', entity_id = $row.key, revision = type::string(rand::uuid()); }; CREATE knowledge_meta:backfill_v1; }; COMMIT;",
  );
}
async function knowledgePrepare(db: Database, epoch: string) {
  if (!epoch || epoch.length > 200) throw Error("Identidad de proyección inválida");
  await run(
    db,
    "BEGIN; LET $current = (SELECT VALUE epoch FROM knowledge_meta:projection); IF $current != [$epoch] { FOR $row IN (SELECT key FROM recording) { LET $key = 'recording:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'recording', entity_id = $row.key, revision = type::string(rand::uuid()); }; FOR $row IN (SELECT key FROM person) { LET $key = 'person:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'person', entity_id = $row.key, revision = type::string(rand::uuid()); }; UPSERT knowledge_meta:projection SET epoch = $epoch; }; COMMIT;",
    { epoch },
  );
}
const strings = (value: Json, keys: string[]): Record<string, Json> => {
  const result: Record<string, Json> = {};
  if (isObject(value)) for (const key of keys) if (typeof value[key] === "string") result[key] = value[key] as Json;
  return result;
};
const timing = (value: Json, result: Record<string, Json>) => {
  if (isObject(value)) for (const key of ["start", "end", "duration"]) if (typeof value[key] === "number") result[key] = value[key] as Json;
  return result;
};
function publicTranscript(value: Json): Record<string, Json> {
  const result = timing(value, strings(value, ["text", "language"]));
  const segments = isObject(value) && Array.isArray(value.segments) ? value.segments : [];
  result.segments = segments.map((segment) => {
    const item = timing(segment, strings(segment, ["text", "speaker", "personId"]));
    if (isObject(segment) && Array.isArray(segment.words)) item.words = segment.words.map((word) => timing(word, strings(word, ["text"])));
    return item;
  });
  return result;
}
async function recordingSnapshot(db: Database, id: string): Promise<Json | null> {
  const row = await rowByKey(db, "recording", id);
  if (!row) return null;
  if (!isObject(row.payload)) throw Error("Grabación guardada inválida");
  if (row.payload.status === "discarded") return null;
  if (row.payload.id !== id) throw Error("Grabación guardada inválida");
  const result = timing(row.payload, strings(row.payload, ["id", "status", "title", "createdAt", "currentVersionId"]));
  const versions = (await rowsForParent(db, "version", id)).sort((a, b) => a.position - b.position);
  result.versions = versions.map((version) => {
    readVersion(version.payload, "Versión guardada inválida para la base de conocimiento");
    const value = version.payload;
    const item = strings(value, ["id", "createdAt", "backend", "recipeId", "title"]);
    if (isObject(value) && isObject(value.transcript)) item.transcript = publicTranscript(value.transcript);
    if (isObject(value) && isObject(value.digest)) {
      const digest = strings(value.digest, ["title", "summary", "description"]);
      if (Array.isArray(value.digest.tags)) digest.tags = value.digest.tags.filter((tag): tag is string => typeof tag === "string");
      item.digest = digest;
    }
    return item;
  });
  return result;
}
async function knowledgeChange(db: Database): Promise<CoreChange | undefined> {
  const [found] = await run<[{ key: string; revision: string; kind: string; entity_id: string }[]]>(db, "SELECT key, revision, kind, entity_id FROM knowledge_dirty ORDER BY key LIMIT 1");
  const row = found?.[0];
  if (!row) return undefined;
  let value: Json | null;
  if (row.kind === "recording") value = await recordingSnapshot(db, row.entity_id);
  else if (row.kind === "person") {
    const [people] = await run<[Json[]]>(db, "SELECT payload.id AS id, payload.name AS name, payload.color AS color, payload.created_at AS createdAt FROM type::record('person', $key)", { key: row.entity_id });
    const person = people?.[0];
    value = person === undefined ? null : strings(person, ["id", "name", "color", "createdAt"]);
  } else throw Error("Tipo de cambio de conocimiento desconocido");
  return { key: row.key, revision: row.revision, kind: row.kind, id: row.entity_id, value };
}
async function knowledgeAck(db: Database, key: string, revision: string) {
  await run(db, "DELETE type::record('knowledge_dirty', $key) WHERE revision = $revision", { key, revision });
}
