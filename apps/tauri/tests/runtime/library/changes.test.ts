import { test } from "vitest";
import assert from "node:assert/strict";
import { changes, type RowOp } from "../../../src/runtime/library/changes";
import { readLibraryData, type LibraryData, type Recording } from "../../../src/runtime/library/model";
import { clone } from "../../../src/runtime/library/json";

function library(recordings: unknown[]): LibraryData {
  return readLibraryData({
    schemaVersion: 1,
    recordings,
    accounts: [],
    resolvers: [{ id: "local-stt", name: "Whisper", role: "stt" }, { id: "remoto", name: "Remoto", role: "stt" }],
    recipes: [{ id: "default", name: "Por defecto", kind: "form", values: { stt: "remoto" } }],
    destinations: [],
    settings: { language: "es", defaultRecipeId: "default" },
  });
}
const note = (id: string, createdAt: string) => ({
  id,
  title: id,
  createdAt,
  status: "done",
  versions: [{ id: `${id}-v`, transcript: { text: "texto", segments: [] } }],
  publications: [],
});
const many = () => Array.from({ length: 50 }, (_, index) => note(`n${index}`, `2026-10-${String((index % 28) + 1).padStart(2, "0")}T00:00:00Z`));
const written = (ops: RowOp[]) => ops.map((op) => (op.kind === "upsert" ? [op.row.table, op.row.key] : [op.table, op.key]));

test("incorporar una nota al principio solo escribe esa nota", () => {
  const before = library(many());
  const after = clone(before);
  after.recordings.unshift(note("nueva", "2026-10-11T10:00:00Z") as Recording);
  assert.deepEqual(written(changes(before, after, new Set())), [["recording", "nueva"]]);
});

test("una nota nueva acotada escribe también sus versiones", () => {
  const before = library(many());
  const after = clone(before);
  after.recordings.unshift(note("nueva", "2026-10-11T10:00:00Z") as Recording);
  assert.deepEqual(written(changes(before, after, new Set(["nueva"]))), [["recording", "nueva"], ["version", '["nueva","nueva-v"]']]);
});

test("cambiar el título no reescribe versiones ni otras notas", () => {
  const before = library(many());
  const after = clone(before);
  after.recordings[7]!.title = "Otro";
  assert.deepEqual(written(changes(before, after, new Set([after.recordings[7]!.id]))), [["recording", "n7"]]);
});

test("corregir una versión no reescribe la nota", () => {
  const before = library(many());
  const after = clone(before);
  after.recordings[3]!.versions![0]!.digest = { title: "T", summary: "S", tags: [] };
  assert.deepEqual(written(changes(before, after, new Set(["n3"]))), [["version", '["n3","n3-v"]']]);
});

test("versiones de notas fuera del ámbito no se escriben", () => {
  const before = library(many());
  const after = clone(before);
  after.recordings[3]!.versions![0]!.digest = { title: "T", summary: "S", tags: [] };
  assert.deepEqual(changes(before, after, new Set()), []);
});

test("quitar un resolutor escribe el catálogo y la receta que lo nombraba", () => {
  const before = library(many());
  const after = clone(before);
  (after.resolvers as unknown[]).splice(1, 1);
  (after.recipes as Record<string, unknown>[])[0]!.values = {};
  const ops = changes(before, after, new Set());
  assert.deepEqual(written(ops), [["recipe", "default"], ["resolver", "remoto"]]);
  assert.equal(ops[1]!.kind, "delete");
});

test("un ajuste cambiado es una sola fila", () => {
  const before = library(many());
  const after = clone(before);
  after.settings.language = "en";
  assert.deepEqual(written(changes(before, after, new Set())), [["setting", "language"]]);
});

test("quitar una nota la borra por su identidad", () => {
  const before = library(many());
  const after = clone(before);
  after.recordings.splice(10, 1);
  const ops = changes(before, after, new Set());
  assert.deepEqual(written(ops), [["recording", "n10"]]);
  assert.equal(ops[0]!.kind, "delete");
});

test("rechaza identidades duplicadas y notas sin versiones", () => {
  const before = library([]);
  const duplicated = clone(before);
  const copy = note("igual", "2026-10-11T00:00:00Z") as Recording;
  duplicated.recordings = [copy, clone(copy)];
  assert.throws(() => changes(before, duplicated, "all"), /duplicado/);
  const broken = library([{ id: "rota", status: "done" }]);
  assert.throws(() => changes(before, broken, "all"), /versions inválido/);
  const tombstone = library([{ id: "lapida", status: "discarded" }]);
  assert.deepEqual(written(changes(before, tombstone, "all")), [["recording", "lapida"]]);
});

test("sin cambios no hay escrituras", () => {
  const before = library(many());
  assert.deepEqual(changes(before, clone(before), "all"), []);
});
