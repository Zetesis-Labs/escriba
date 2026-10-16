import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller";
import { snapshot, runtimeContext } from "./fixture";
import type { RuntimeHost } from "../../src/runtime/contracts";
import { RuntimeError, errorCode } from "../../src/runtime/contracts";

function fixture() {
  const state = structuredClone(snapshot);
  const dependency = { id: "example.topics", minVersion: 1, maxVersion: 2 };
  state.recipes = [{ id: "graph", name: "Grafo", kind: "code", bundle: "graph-program", values: {}, ontologies: [dependency] }];
  state.settings.defaultRecipeId = "graph";
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const host: RuntimeHost = { call: async (method, params = {}) => {
    calls.push({ method, params });
    if (method === "runtime_context") return runtimeContext(state, params.recordingId);
    if (method === "knowledge_open") return { version: 1 };
    if (method === "knowledge_query") return "gA==";
    if (method === "account_effect_begin") state.recordings[0].accountEffectPending = true;
    if (method === "account_effect_finish") state.recordings[0].accountEffectPending = false;
    if (method === "transcribe") return { text: "Prueba sintética", segments: [] };
    if (method === "version_save") return { ...params, id: "v", createdAt: "now" };
    return null;
  } };
  return { state, calls, host, dependency };
}

test("el acceso al grafo usa la dependencia de la receta elegida y hereda la base de un formulario", async () => {
  const f = fixture();
  f.state.recipes.push({ id: "form", name: "Formulario", kind: "form", base: "graph", values: {} });
  f.state.settings.defaultRecipeId = "form";
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    assert.deepEqual(await context.call("graph.open", { ontologyId: "example.topics", recipeId: "forged", dependency: { id: "wrong", minVersion: 1, maxVersion: 99 } }), { version: 1 });
    await assert.rejects(context.call("graph.open", { ontologyId: "other" }), /no declara/);
    await context.call("transcribe", {});
    return null;
  } });
  await runtime.processRecording("r");
  assert.deepEqual(f.calls.find((c) => c.method === "knowledge_open")?.params, {
    recipeId: "form", recordingId: "r", ontologyId: "example.topics", dependency: f.dependency,
  });
  assert.equal(f.calls.some((c) => c.method === "account_effect_begin"), false);
});

test("una consulta incierta al grafo se marca antes de enviarse y no se repite automáticamente", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    assert.equal(await context.call("graph.query", { ontologyId: "example.topics", expectedVersion: 1, sql: "CREATE topic CONTENT $data", bindings: "oA==" }), "gA==");
    throw new RuntimeError("Proceso interrumpido", "backend_unavailable");
  } });
  await assert.rejects(runtime.processRecording("r"), (error) => {
    assert.equal(errorCode(error), "failed");
    assert.match(String(error), /sobre el grafo/);
    return true;
  });
  const methods = f.calls.map((c) => c.method);
  assert.ok(methods.indexOf("account_effect_begin") < methods.indexOf("knowledge_query"));
  await assert.rejects(runtime.processRecording("r", { force: false }), /Revisa la operación/);
  assert.equal(f.calls.filter((c) => c.method === "knowledge_query").length, 1);
});

test("la prueba y las dependencias ausentes deniegan el grafo antes de cualquier consulta", async () => {
  for (const dryRun of [true, false]) {
    const f = fixture();
    if (!dryRun) f.state.recipes[0].ontologies = [];
    const runtime = createRuntime(f.host, { run: async (_, context) => context.call("graph.open", { ontologyId: "example.topics" }) });
    await assert.rejects(runtime.processRecording("r", { dryRun }), dryRun ? /prueba de receta/ : /no declara/);
    assert.equal(f.calls.some((c) => c.method.startsWith("knowledge_") || c.method === "account_effect_begin"), false);
  }
});

test("vincular usa únicamente una nota de esta ejecución y la versión que guarda", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    const note = (await context.call("transcribe", {})) as { handle: string };
    await assert.rejects(context.call("graph.link", { ontologyId: "example.topics", expectedVersion: 1, recordId: "topic:a", noteId: "v" }), /no pertenece a esta ejecución/);
    await context.call("graph.link", { ontologyId: "example.topics", expectedVersion: 1, recordId: "topic:a", noteId: note.handle });
    return null;
  } });
  await runtime.processRecording("r");
  assert.deepEqual(f.calls.find((c) => c.method === "knowledge_link")?.params, {
    recipeId: "graph", recordingId: "r", ontologyId: "example.topics", dependency: f.dependency,
    expectedVersion: 1, versionId: "v", recordId: "topic:a",
  });
});

test("la base de Escriba se abre de forma implícita y rechaza vínculos manuales", async () => {
  const f = fixture();
  f.state.recipes[0].ontologies = [];
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    assert.deepEqual(await context.call("graph.open", { ontologyId: "escriba" }), { version: 1 });
    assert.equal(await context.call("graph.query", { ontologyId: "escriba", expectedVersion: 1, sql: "SELECT id FROM segment", bindings: "oA==" }), "gA==");
    await assert.rejects(context.call("graph.link", { ontologyId: "escriba", expectedVersion: 1, recordId: "segment:sample", noteId: "v" }), /base de Escriba/);
    await context.call("transcribe", {});
    return null;
  } });
  await runtime.processRecording("r");
  assert.deepEqual(f.calls.find((c) => c.method === "knowledge_open")?.params, {
    recipeId: "graph", recordingId: "r", ontologyId: "escriba", dependency: { id: "escriba", minVersion: 1, maxVersion: 1 },
  });
  assert.equal(f.calls.some((c) => c.method === "knowledge_link"), false);
  assert.equal(f.calls.some((c) => c.method === "account_effect_begin"), false);
});

test("la prueba de receta tampoco abre la base de Escriba", async () => {
  const f = fixture();
  f.state.recipes[0].ontologies = [];
  const runtime = createRuntime(f.host, { run: async (_, context) => context.call("graph.open", { ontologyId: "escriba" }) });
  await assert.rejects(runtime.processRecording("r", { dryRun: true }), /prueba de receta/);
  assert.equal(f.calls.some((c) => c.method.startsWith("knowledge_")), false);
});
