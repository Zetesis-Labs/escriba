import { canonical, isObject, text, type Json } from "./json";
import { catalog, type LibraryData, type Recording } from "./model";

export type Table =
  | "recording"
  | "version"
  | "publication"
  | "account"
  | "resolver"
  | "recipe"
  | "destination"
  | "provider"
  | "setting";
export const preview = (table: Table): string | undefined =>
  table === "version" ? "version_preview" : table === "publication" ? "publication_preview" : undefined;
const CATALOG_TABLES: [Table, string][] = [
  ["account", "accounts"],
  ["resolver", "resolvers"],
  ["recipe", "recipes"],
  ["destination", "destinations"],
  ["provider", "providers"],
];
export interface RowWrite {
  table: Table;
  key: string;
  parent: string;
  position: number;
  payload: Json;
}
export type RowOp = { kind: "upsert"; row: RowWrite } | { kind: "delete"; table: Table; key: string; id: string };
export type Children = "all" | ReadonlySet<string>;
const includes = (children: Children, id: string) => children === "all" || children.has(id);

export function recordingPayload(record: Recording): Record<string, Json> {
  const { versions: _versions, publications: _publications, ...payload } = record;
  return payload as Record<string, Json>;
}
export const childKey = (recordingId: string, id: string) => JSON.stringify([recordingId, id]);

function childValues(record: Recording, table: Table): Json[] {
  const [values, field] = table === "version" ? [record.versions, "versions"] : [record.publications, "publications"];
  if (Array.isArray(values)) return values as Json[];
  if (record.status === "discarded") return [];
  throw Error(`${field} inválido`);
}
function childRows(old: Recording | undefined, record: Recording, upserts: RowOp[], deletes: RowOp[]) {
  for (const [table, idField] of [["version", "id"], ["publication", "destinationId"]] as [Table, string][]) {
    const previous = new Map<string, { position: number; child: Json }>();
    if (old)
      childValues(old, table).forEach((child, position) => {
        previous.set(childId(child, table, idField), { position, child });
      });
    const seen = new Set<string>();
    childValues(record, table).forEach((child, position) => {
      const id = childId(child, table, idField);
      if (seen.has(id)) throw Error("Identificador duplicado en la biblioteca");
      seen.add(id);
      const before = previous.get(id);
      if (before && before.position === position && canonical(before.child) === canonical(child)) return;
      upserts.push({ kind: "upsert", row: { table, key: childKey(record.id, id), parent: record.id, position, payload: child } });
    });
    for (const id of previous.keys())
      if (!seen.has(id)) deletes.push({ kind: "delete", table, key: childKey(record.id, id), id });
  }
}
function childId(child: Json, table: Table, idField: string): string {
  const id = isObject(child) ? child[idField] : undefined;
  if (typeof id !== "string") throw Error(`${table} sin ${idField}`);
  return id;
}
function recordings(before: LibraryData, after: LibraryData, children: Children, upserts: RowOp[], deletes: RowOp[]) {
  const previous = new Map(before.recordings.map((record) => [record.id, record]));
  const seen = new Set<string>();
  for (const record of after.recordings) {
    if (seen.has(record.id)) throw Error("Identificador duplicado en la biblioteca");
    seen.add(record.id);
    const old = previous.get(record.id);
    const payload = recordingPayload(record);
    if (!old || canonical(recordingPayload(old)) !== canonical(payload))
      upserts.push({ kind: "upsert", row: { table: "recording", key: record.id, parent: "", position: 0, payload } });
    if (includes(children, record.id)) childRows(old, record, upserts, deletes);
  }
  for (const old of before.recordings)
    if (!seen.has(old.id)) deletes.push({ kind: "delete", table: "recording", key: old.id, id: old.id });
}
function catalogRows(table: Table, field: string, before: Json[], after: Json[], upserts: RowOp[], deletes: RowOp[]) {
  const previous = new Map<string, { position: number; item: Json }>();
  before.forEach((item, position) => previous.set(text(item, "id"), { position, item }));
  const seen = new Set<string>();
  after.forEach((item, position) => {
    let id: string;
    try {
      id = text(item, "id");
    } catch {
      throw Error(`${field} sin ID`);
    }
    if (seen.has(id)) throw Error("Identificador duplicado en la biblioteca");
    seen.add(id);
    const old = previous.get(id);
    if (old && old.position === position && canonical(old.item) === canonical(item)) return;
    upserts.push({ kind: "upsert", row: { table, key: id, parent: "", position, payload: item } });
  });
  for (const id of previous.keys()) if (!seen.has(id)) deletes.push({ kind: "delete", table, key: id, id });
}
function settingRows(before: LibraryData, after: LibraryData, upserts: RowOp[], deletes: RowOp[]) {
  const previous = before.settings as Record<string, Json | undefined>;
  const current = after.settings as Record<string, Json | undefined>;
  for (const [key, value] of Object.entries(current)) {
    if (value === undefined) continue;
    if (key in previous && previous[key] !== undefined && canonical(previous[key]) === canonical(value)) continue;
    upserts.push({ kind: "upsert", row: { table: "setting", key, parent: "", position: 0, payload: value } });
  }
  for (const key of Object.keys(previous))
    if (previous[key] !== undefined && current[key] === undefined) deletes.push({ kind: "delete", table: "setting", key, id: key });
}
export function changes(before: LibraryData, after: LibraryData, children: Children): RowOp[] {
  const upserts: RowOp[] = [];
  const deletes: RowOp[] = [];
  recordings(before, after, children, upserts, deletes);
  for (const [table, field] of CATALOG_TABLES) catalogRows(table, field, catalog(before, field), catalog(after, field), upserts, deletes);
  settingRows(before, after, upserts, deletes);
  return [...upserts, ...deletes];
}
