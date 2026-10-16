import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller.js";
import type { RuntimeRunner, WorkerContext, WorkerTask } from "../../src/runtime/contracts.js";
import { BUILTIN_RECIPES } from "../../src/core/builtinRecipes.js";
import type { Snapshot, Version } from "../../src/types.js";
import { snapshot, runtimeContext } from "./fixture";

const version = (id: string, text: string): Version =>
  ({ id, createdAt: "2026-10-09T10:00:00Z", backend: "local-stt", recipeId: "default", transcript: { text, segments: [] }, inputs: {} }) as unknown as Version;

function library(versions: Version[] = [], currentVersionId?: string) {
  const state: Snapshot = structuredClone({ ...snapshot, recipes: [...BUILTIN_RECIPES] });
  state.recordings[0].versions = structuredClone(versions);
  if (currentVersionId) state.recordings[0].currentVersionId = currentVersionId;
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const memory = new Map<string, unknown>();
  let summaries = 0;
  const host = {
    call: async (method: string, params: Record<string, unknown> = {}) => {
      calls.push({ method, params });
      if (method === "runtime_context") return runtimeContext(state, params.recordingId);
      if (method === "version_save") {
        const saved = { ...version(`v${state.recordings[0].versions.length + 1}`, "nueva"), ...params } as unknown as Version;
        state.recordings[0].versions.push(saved);
        return saved;
      }
      if (method === "transcribe") return { text: "nueva", segments: [] };
      if (method === "summarize") return { title: `Resumen ${++summaries}`, summary: "Breve", tags: [] };
      if (method === "memory_recall") return memory.get(`${params.versionId}:${params.fingerprint}`) ?? null;
      if (method === "memory_keep") memory.set(`${params.versionId}:${params.fingerprint}`, params.value);
      return undefined;
    },
  };
  const writes = () => calls.filter((call) => ["version_save", "version_update", "version_select"].includes(call.method));
  return { state, host, calls, writes, summaries: () => summaries };
}

function runner(steps: (context: WorkerContext) => Promise<unknown>, tasks: WorkerTask[] = []): RuntimeRunner {
  return {
    run: async (task, context) => {
      tasks.push(task);
      return task.kind === "recipe" ? steps(context) : { type: "object", properties: {} };
    },
  };
}

test("sin ninguna versión la nota no existe y la receta no escribe nada", async () => {
  const notes: unknown[] = [];
  const { host, writes } = library();
  const controller = createRuntime(host, runner(async (context) => notes.push(await context.call("note", {}))));
  await assert.rejects(controller.processRecording("r"), /no produjo una transcripción/);
  assert.deepEqual(notes, [null]);
  assert.deepEqual(writes(), []);
});

test("la nota es la vigente: resumir y guardar escriben en ella sin crear versión", async () => {
  const { host, writes } = library([version("v1", "antigua"), version("v2", "corregida")], "v2");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const note = (await context.call("note", {})) as { handle: string; texto: string };
      assert.deepEqual([note.handle, note.texto], ["v2", "corregida"]);
      await context.call("summarize", { handle: note.handle });
      await context.call("save", { handle: note.handle, data: null });
      return null;
    }),
  );
  assert.deepEqual(await controller.processRecording("r"), { versionId: "v2" });
  assert.deepEqual(
    writes().map((call) => [call.method, call.params.versionId]),
    [["version_update", "v2"], ["version_update", "v2"], ["version_select", "v2"]],
  );
});

test("tras transcribir, la nota es la versión del trabajo aunque no sea la vigente", async () => {
  const { host } = library([version("v1", "antigua")], "v1");
  const handles: string[] = [];
  const controller = createRuntime(
    host,
    runner(async (context) => {
      handles.push(((await context.call("transcribe", {})) as { handle: string }).handle);
      handles.push(((await context.call("note", {})) as { handle: string }).handle);
      return null;
    }),
  );
  await controller.processRecording("r");
  assert.equal(handles[0], handles[1]);
  assert.notEqual(handles[1], "v1");
});

test("al probar una receta la nota se lee y el resumen no se guarda", async () => {
  const { host, writes } = library([version("v1", "texto")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const note = (await context.call("note", {})) as { handle: string };
      await context.call("summarize", { handle: note.handle });
      return null;
    }),
  );
  await controller.processRecording("r", { dryRun: true });
  assert.deepEqual(writes(), []);
});

test("un reprocesado a mano rehace el resumen de la vigente una vez y sus reintentos lo recuerdan", async () => {
  const { host, summaries } = library([version("v1", "texto")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const note = (await context.call("note", {})) as { handle: string };
      await context.call("summarize", { handle: note.handle });
      await context.call("summarize", { handle: note.handle });
      return null;
    }),
  );
  await controller.processRecording("r", { force: true });
  assert.equal(summaries(), 1);
  await controller.processRecording("r", { force: true });
  assert.equal(summaries(), 2);
  await controller.processRecording("r", { force: false });
  assert.equal(summaries(), 2);
});

test("cada receta de serie llega al worker con su programa, también sus variantes", async () => {
  const { state, host } = library([version("v1", "texto")], "v1");
  state.recipes.push({ id: "variante", name: "Resumir con otro", kind: "form", builtin: "resumir", values: { prompt: "Corto" } });
  const tasks: WorkerTask[] = [];
  const controller = createRuntime(host, runner(async (context) => context.call("note", {}), tasks));
  for (const recipeId of ["default", "serie:transcribir", "serie:resumir", "serie:publicar", "variante"]) await controller.processRecording("r", { recipeId });
  await controller.getRecipeSchema("serie:publicar");
  assert.deepEqual(
    tasks.map((task) => [task.kind, task.program, task.payload.builtin]),
    [
      ["recipe", undefined, "por-defecto"],
      ["recipe", undefined, "transcribir"],
      ["recipe", undefined, "resumir"],
      ["recipe", undefined, "publicar"],
      ["recipe", undefined, "resumir"],
      ["recipe-schema", undefined, "publicar"],
    ],
  );
  assert.deepEqual(tasks[4].payload.values, { prompt: "Corto", idioma: "es" });
});

test("una receta de código no recibe programa de serie", async () => {
  const { state, host } = library([version("v1", "texto")], "v1");
  state.recipes.push({ id: "ejemplo", name: "Ejemplo", kind: "code", values: {}, bundle: "var __recipe={}" });
  const tasks: WorkerTask[] = [];
  const controller = createRuntime(host, runner(async (context) => context.call("note", {}), tasks));
  await controller.processRecording("r", { recipeId: "ejemplo" });
  assert.deepEqual([tasks[0].program, tasks[0].payload.builtin], ["var __recipe={}", undefined]);
});
