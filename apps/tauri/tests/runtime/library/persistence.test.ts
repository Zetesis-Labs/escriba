import { test } from "vitest";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Persistence, scope } from "../../../src/runtime/library/persistence";
import { clone, type Json } from "../../../src/runtime/library/json";
import { openDatabase, rowsForParent, run } from "../../../src/runtime/library/surreal";

const empty = () => ({ schemaVersion: 1, recordings: [], accounts: [], resolvers: [], recipes: [], destinations: [], logs: [], settings: {} });
const library = () => ({
  schemaVersion: 1,
  recordings: [{ id: "r", status: "done", title: "Nota", currentVersionId: "v", versions: [{ id: "v", recipeId: "old", backend: "local", transcript: { text: "secreto completo", segments: [{ start: 0, end: 1, text: "secreto", words: [{ start: 0, end: 1, text: "secreto" }] }] } }], publications: [] }],
  accounts: [], resolvers: [], recipes: [], destinations: [], logs: [], settings: {},
});
type Obj = Record<string, Json>;
const rec = (value: unknown) => (value as Obj).recordings as Obj[];

async function open() {
  const directory = await mkdtemp(join(tmpdir(), "escriba-persistence-"));
  const db = await Persistence.open(join(directory, "library.rocksdb"));
  return { db, async close() { await db.close(); await rm(directory, { recursive: true, force: true }); } };
}

test("índice ligero y detalle conservan transcripción", async () => {
  const { db, close } = await open();
  try {
    const full = library();
    full.recordings[0]!.versions[0]!.transcript.text = `${"x".repeat(500)}MARCADOR_FINAL`;
    await db.save(empty(), full);
    const index = (await db.loadIndex()) as Obj;
    assert.ok(!JSON.stringify(index).includes("MARCADOR_FINAL"));
    const version = (rec(index)[0]!.versions as Obj[])[0]!;
    assert.equal(Array.from((version.transcript as Obj).text as string).length, 400);
    assert.deepEqual((version.transcript as Obj).segments, []);
    assert.deepEqual(await db.recording("r"), full.recordings[0]);
  } finally {
    await close();
  }
});

test("cambio acotado conserva hijos ajenos y remapea receta", async () => {
  const { db, close } = await open();
  try {
    const full = library();
    (full.recordings[0] as Obj).publications = [{ destinationId: "d", provider: "notion", receipt: { state: "published", locator: "x", privateBundle: "paquete oculto" } }];
    await db.save(empty(), full);
    const before = (await db.loadIndex()) as Obj;
    const after = clone(before);
    rec(after)[0]!.title = "Nuevo";
    await db.saveScoped(before, after, scope({ recipeAliases: new Map([["old", "new"]]) }));
    const record = (await db.recording("r")) as Obj;
    assert.equal(((record.versions as Obj[])[0]!.transcript as Obj).text, "secreto completo");
    assert.equal(((record.publications as Obj[])[0]!.receipt as Obj).privateBundle, "paquete oculto");
    const index = (await db.loadIndex()) as Obj;
    assert.ok(!JSON.stringify(index).includes("paquete oculto"));
    assert.equal((record.versions as Obj[])[0]!.recipeId, "new");
    assert.equal((rec(index)[0]!.versions as Obj[])[0]!.recipeId, "new");
  } finally {
    await close();
  }
});

test("intercambio de aliases usa la receta original de cada versión", async () => {
  const { db, close } = await open();
  try {
    const full = library();
    full.recordings[0]!.versions[0]!.recipeId = "A";
    const second = clone(full.recordings[0]!.versions[0]!);
    second.id = "w";
    second.recipeId = "B";
    full.recordings[0]!.versions.push(second);
    await db.save(empty(), full);
    const before = (await db.loadIndex()) as Obj;
    await db.saveScoped(clone(before), before, scope({ recipeAliases: new Map([["A", "B"], ["B", "A"]]) }));
    const record = (await db.recording("r")) as Obj;
    assert.equal((record.versions as Obj[])[0]!.recipeId, "B");
    assert.equal((record.versions as Obj[])[1]!.recipeId, "A");
    const index = (await db.loadIndex()) as Obj;
    assert.equal((rec(index)[0]!.versions as Obj[])[0]!.recipeId, "B");
    assert.equal((rec(index)[0]!.versions as Obj[])[1]!.recipeId, "A");
  } finally {
    await close();
  }
});

test("cadena de aliases no aplica dos saltos a una versión", async () => {
  const { db, close } = await open();
  try {
    const full = library();
    full.recordings[0]!.versions[0]!.recipeId = "A";
    const second = clone(full.recordings[0]!.versions[0]!);
    second.id = "w";
    second.recipeId = "B";
    full.recordings[0]!.versions.push(second);
    await db.save(empty(), full);
    const before = (await db.loadIndex()) as Obj;
    await db.saveScoped(clone(before), before, scope({ recipeAliases: new Map([["A", "B"], ["B", "C"]]) }));
    const record = (await db.recording("r")) as Obj;
    assert.equal((record.versions as Obj[])[0]!.recipeId, "B");
    assert.equal((record.versions as Obj[])[1]!.recipeId, "C");
  } finally {
    await close();
  }
});

test("versión hidratada actualiza proyección y detalle", async () => {
  const { db, close } = await open();
  try {
    await db.save(empty(), library());
    const before = (await db.loadIndex()) as Obj;
    rec(before)[0] = (await db.recording("r")) as Obj;
    const after = clone(before);
    ((rec(after)[0]!.versions as Obj[])[0]!.transcript as Obj).text = "nuevo texto";
    await db.saveScoped(before, after, scope({ fullRecordings: new Set(["r"]) }));
    assert.equal((((await db.recording("r")) as Obj).versions as Obj[])[0]!.transcript && ((((await db.recording("r")) as Obj).versions as Obj[])[0]!.transcript as Obj).text, "nuevo texto");
    assert.equal(((rec((await db.loadIndex()) as Obj)[0]!.versions as Obj[])[0]!.transcript as Obj).text, "nuevo texto");
  } finally {
    await close();
  }
});

test("fallo de escritura acotada revierte metadatos", async () => {
  const { db, close } = await open();
  try {
    await db.save(empty(), library());
    const before = (await db.loadIndex()) as Obj;
    await db.queryTest("DEFINE FIELD OVERWRITE title ON TABLE recording ASSERT $value != 'Prohibido'");
    const after = clone(before);
    rec(after)[0]!.title = "Prohibido";
    await assert.rejects(db.saveScoped(clone(before), after, scope()));
    assert.deepEqual(await db.loadIndex(), before);
    assert.equal(((((await db.recording("r")) as Obj).versions as Obj[])[0]!.transcript as Obj).text, "secreto completo");
  } finally {
    await close();
  }
});

test("descarte acotado borra versiones y recibos no hidratados", async () => {
  const { db, close } = await open();
  try {
    const full = library();
    (full.recordings[0] as Obj).publications = [{ destinationId: "d", receipt: { state: "published", locator: "x" } }];
    await db.save(empty(), full);
    const before = (await db.loadIndex()) as Obj;
    const after = clone(before);
    rec(after)[0] = { id: "r", status: "discarded", source: null, sourceKey: null, legacyKey: null };
    await db.saveScoped(before, after, scope());
    const record = (await db.recording("r")) as Obj;
    assert.equal(record.versions, undefined);
    assert.equal(record.publications, undefined);
    assert.equal(record.status, "discarded");
  } finally {
    await close();
  }
});

test("índice rechaza proyección huérfana y detalle hijo sin proyección", async () => {
  const { db, close } = await open();
  try {
    await db.save(empty(), library());
    await db.loadIndex();
    await db.queryTest("CREATE version_preview:orphan SET key = '[\"ausente\",\"v\"]', parent = 'ausente', position = 0, payload = { id: 'v', transcript: { text: 'contenido', segments: [] } }");
    await assert.rejects(db.loadIndex(), /huérfana/);
    await db.queryTest("DELETE version_preview:orphan");
    await db.queryTest("CREATE version:extra SET key = '[\"r\",\"extra\"]', parent = 'r', position = 1, payload = { id: 'extra', transcript: { text: 'contenido', segments: [] } }");
    await assert.rejects(db.recording("r"), /proyección/);
  } finally {
    await close();
  }
});

test("backfill rechaza versión corrupta sin marcarse completo", async () => {
  const { db, close } = await open();
  try {
    await db.save(empty(), library());
    await db.queryTest("UPDATE version SET payload.backend = true");
    await db.queryTest("DELETE meta:preview_v1");
    await assert.rejects(db.loadIndex(), /Versión guardada inválida/);
    assert.deepEqual(await db.selectTest("SELECT key FROM meta WHERE key = 'preview_v1'"), []);
  } finally {
    await close();
  }
});

test("consulta dinámica por parent usa el índice en SurrealDB", async () => {
  const directory = await mkdtemp(join(tmpdir(), "escriba-plan-"));
  const db = await openDatabase(join(directory, "plan.rocksdb"), "test", "index_plan");
  try {
    await run(db, "DEFINE TABLE version SCHEMALESS; DEFINE INDEX idx_version_parent ON TABLE version FIELDS parent; CREATE version:a SET parent = 'r', position = 0, payload = {id: 'a'}; CREATE version:b SET parent = 'other', position = 1, payload = {id: 'b'}");
    const unusual = "comilla ' doble \" barra \\ eñe ñ\nlínea";
    await run(db, "CREATE version:quoted SET key = 'quoted', parent = $parent, position = 2, payload = {id: 'quoted'}", { parent: unusual });
    const found = await rowsForParent(db, "version", unusual);
    assert.equal(found.length, 1);
    assert.equal(found[0]!.key, "quoted");
    for (const source of ["version", "type::table($table)"]) {
      const [plan] = await run<[string]>(db, `EXPLAIN ANALYZE SELECT key, parent, position, payload FROM ${source} WHERE parent = ${JSON.stringify("r")}`, { table: "version" });
      const text = JSON.stringify(plan);
      assert.ok(text.includes("IndexScan") && text.includes("idx_version_parent"), `${source} no usó el índice: ${text}`);
    }
  } finally {
    await db.close();
    await rm(directory, { recursive: true, force: true });
  }
});
