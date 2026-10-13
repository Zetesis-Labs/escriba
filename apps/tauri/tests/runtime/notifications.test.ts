import { test } from "vitest";
import assert from "node:assert/strict";
import { finished, notification, resolverProblem, settingsChanged, transcribed } from "../../src/runtime/notifications";
import type { Json } from "../../src/runtime/library/json";

const automatic = { operation: "processRecording", automatic: true, recordingId: "nota" };
const recording = { versions: [{ id: "v1", transcript: { text: "Hola" } }] };
const failure = (code: "backend_unavailable" | "recipe_unavailable" | "failed", message: string) => ({ ok: false as const, error: { code, message } });
const success = { ok: true as const, value: { versionId: "v1" } };

test("revisa resolutores al cambiar los ajustes que reconstruyen el pipeline", () => {
  assert.ok(settingsChanged("config_save", { collection: "resolvers" }));
  assert.ok(settingsChanged("config_remove", { collection: "resolvers" }));
  assert.ok(settingsChanged("connector_save", {}));
  assert.ok(settingsChanged("connector_remove", {}));
  assert.ok(settingsChanged("settings_save", { settings: { watchedFolders: [] } }));
  assert.ok(!settingsChanged("config_save", { collection: "recipes" }));
  assert.ok(!settingsChanged("settings_save", { settings: { notifyEveryNote: false } }));
});

test("los problemas automáticos se avisan también en reintentos con el éxito desactivado", () => {
  for (const [code, title, body] of [
    ["backend_unavailable", "El motor de transcripción no responde", "Sin conexión"],
    ["recipe_unavailable", "La receta por defecto no está disponible", "Falta el paquete"],
    ["failed", "Fallo al transcribir nota", "Audio ilegible"],
  ] as const) {
    const notice = finished({ ...automatic, attempt: 3 }, {}, failure(code, body), { notifyEveryNote: false });
    assert.deepEqual(notice, { title, body, sound: true });
  }
});

test("no avisa de operaciones manuales, pruebas, cancelaciones ni esperas", () => {
  const jobs: Json[] = [
    { operation: "processRecording", automatic: false, attempt: 2 },
    { operation: "processRecording", automatic: true, args: { options: { dryRun: true } } },
    { operation: "summarizeRecording", automatic: true },
    { operation: "publishRecording", automatic: true },
  ];
  for (const job of jobs) {
    assert.equal(finished(job, recording, success, { notifyEveryNote: true }), undefined);
    assert.equal(finished(job, recording, failure("backend_unavailable", "Sin conexión"), { notifyEveryNote: false }), undefined);
  }
  assert.equal(finished({ operation: "processRecording", automatic: true }, recording, failure("failed", "Proceso cancelado"), { notifyEveryNote: true }), undefined);
});

test("una instalación nueva notifica igual que el ajuste activado por defecto", () => {
  assert.equal(finished(automatic, recording, success, {})?.body, "Hola");
  assert.equal(finished(automatic, recording, success, { notifyEveryNote: false }), undefined);
});

test("avisa de la versión procesada aunque cambie la selección", () => {
  const changed = { id: "nota", currentVersionId: "v2", versions: [{ id: "v1", transcript: { text: "Hola\nAna" } }, { id: "v2", transcript: { text: "Otra versión" } }] };
  assert.deepEqual(finished(automatic, changed, success, { notifyEveryNote: true }), { title: "Nota transcrita", body: "Hola Ana", sound: false });
});

test("la transcripción recorta ochenta grafemas y no suena", () => {
  const prefix = "é".repeat(80);
  assert.deepEqual(transcribed("clave", `${prefix}Z`, true), { title: "Nota transcrita", body: `${prefix}…`, sound: false });
});

test("el aviso opcional sin texto usa la clave y aplana saltos", () => {
  assert.equal(transcribed("clave", "texto", false), undefined);
  assert.equal(transcribed("clave", " \n ", true)?.body, "clave");
  assert.equal(transcribed("clave", "  primera\nsegunda  ", true)?.body, "primera segunda");
  const exact = "a".repeat(80);
  assert.equal(transcribed("clave", exact, true)?.body, exact);
});

test("los problemas usan los títulos y cuerpos acordados y suenan", () => {
  assert.deepEqual(notification({ kind: "failed", key: "nota-7", reason: "El audio no se pudo abrir" }), { title: "Fallo al transcribir nota-7", body: "El audio no se pudo abrir", sound: true });
  assert.deepEqual(resolverProblem({ role: "stt", name: "Whisper", reason: "Sin modelo" }), { title: "No se puede transcribir con Whisper", body: "Sin modelo", sound: true });
  assert.deepEqual(resolverProblem({ role: "llm", name: "Apple", reason: "Sin modelo" }), { title: "No se puede resumir con Apple", body: "Sin modelo. Las notas se transcribirán igual.", sound: true });
  assert.throws(() => resolverProblem({ role: "otro", name: "x", reason: "y" }), /Rol de resolutor desconocido/);
});

test("el cuerpo de todo aviso se limita a doscientos cuarenta grafemas", () => {
  const prefix = "é".repeat(240);
  assert.equal(notification({ kind: "recipeUnavailable", reason: `${prefix}Z` }).body, prefix);
  assert.equal(transcribed(`${prefix}Z`, "", true)?.body, prefix);
});
