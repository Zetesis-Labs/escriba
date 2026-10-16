import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller.js";
import type { RuntimeRunner, WorkerContext, WorkerTask } from "../../src/runtime/contracts.js";
import { BUILTIN_RECIPES } from "../../src/core/builtinRecipes.js";
import type { JSONObject, Snapshot, Version } from "../../src/types.js";
import { RuntimeError } from "../../src/runtime/contracts.js";
import { snapshot, runtimeContext } from "./fixture";

const plain = { audioHash: "r", backend: "local-stt", model: "large", language: "es", diarize: false, speakers: null };
const diarized = { ...plain, diarize: true };

const version = (id: string, text: string, extra: Partial<Version> = {}): Version =>
  ({ id, createdAt: "2026-10-09T10:00:00Z", backend: "local-stt", recipeId: "default", transcript: { text, segments: [] }, inputs: plain, ...extra }) as unknown as Version;

function library(versions: Version[] = [], currentVersionId?: string) {
  const state: Snapshot = structuredClone({ ...snapshot, recipes: [...BUILTIN_RECIPES] });
  const recording = state.recordings[0];
  recording.versions = structuredClone(versions);
  if (currentVersionId) recording.currentVersionId = currentVersionId;
  if (versions.length) recording.status = "done";
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const memory = new Map<string, unknown>();
  let summaries = 0;
  let transcriptions = 0;
  const host = {
    call: async (method: string, params: Record<string, unknown> = {}) => {
      calls.push({ method, params: structuredClone(params) });
      if (method === "runtime_context") return runtimeContext(state, params.recordingId);
      if (method === "version_save") {
        const { recordingId: _r, select, voicesFrom: _v, ...fields } = params;
        const saved = { id: `v${recording.versions.length + 1}`, createdAt: "2026-10-16T10:00:00Z", hasVoices: false, ...fields } as unknown as Version;
        recording.versions.push(saved);
        if (select !== false) recording.currentVersionId = saved.id;
        return saved;
      }
      if (method === "version_update") {
        const target = recording.versions.find((v) => v.id === params.versionId)!;
        for (const key of ["digest", "data", "transcript", "inputs"] as const) if (key in params) (target as unknown as Record<string, unknown>)[key] = params[key];
        return target;
      }
      if (method === "version_select") recording.currentVersionId = String(params.versionId);
      if (method === "transcribe") return { text: `nueva ${++transcriptions}`, segments: [{ start: 0, end: 1, text: "hola", speaker: params.diarize ? "S1" : "" }] };
      if (method === "summarize") return { title: `Resumen ${++summaries}`, summary: "Breve", tags: [] };
      if (method === "memory_recall") return memory.get(String(params.fingerprint)) ?? null;
      if (method === "memory_keep") memory.set(String(params.fingerprint), params.value);
      return undefined;
    },
  };
  const of = (method: string) => calls.filter((call) => call.method === method).map((call) => call.params);
  const statuses = () => of("recording_update").map((params) => params.status);
  return { state, recording, host, calls, of, statuses, summaries: () => summaries, transcriptions: () => transcriptions };
}

type Note = { handle: string; version: number | null; origen: number | null; texto: string; resumen: { titulo: string } | null; datos: unknown };

function runner(steps: (context: WorkerContext, task: WorkerTask) => Promise<unknown>, tasks: WorkerTask[] = []): RuntimeRunner {
  return {
    run: async (task, context) => {
      tasks.push(task);
      return task.kind === "recipe" ? steps(context, task) : { type: "object", properties: {} };
    },
  };
}

const note = (context: WorkerContext, args: JSONObject = {}) => context.call("note", args) as Promise<Note>;

test("sin versiones la nota está vacía y la receta que no la transcribe falla sin escribir nada", async () => {
  const notes: Note[] = [];
  const { host, of } = library();
  const controller = createRuntime(host, runner(async (context) => notes.push(await note(context))));
  await assert.rejects(controller.processRecording("r"), /no produjo una transcripción/);
  assert.deepEqual([notes[0].version, notes[0].origen, notes[0].texto], [null, null, ""]);
  assert.deepEqual([...of("version_save"), ...of("version_update"), ...of("version_select")], []);
});

test("una grabación nueva transcrita y guardada tiene su primera versión vigente", async () => {
  const { host, recording } = library();
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const created = await note(context);
      await context.call("transcribe", { handle: created.handle });
      await context.call("save", { handle: created.handle, data: null });
    }),
  );
  assert.deepEqual(await controller.processRecording("r"), { versionId: "v1" });
  assert.equal(recording.currentVersionId, "v1");
  assert.equal(recording.versions[0].sourceVersionId, undefined);
});

test("resumir sobre la versión abierta crea una versión nueva con su transcripción y sus datos, y la abierta no cambia", async () => {
  const v4 = version("v4", "cuarta", { data: { tema: "a" }, digest: { title: "Viejo", summary: "x", tags: [] } });
  const { host, recording, of } = library([version("v1", "uno"), version("v2", "dos"), version("v3", "tres"), v4, version("v5", "cinco")], "v5");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      assert.deepEqual([open.version, open.origen, open.texto], [4, 4, "cuarta"]);
      const summarized = (await context.call("summarize", { handle: open.handle })) as Note;
      assert.deepEqual([summarized.version, summarized.origen], [6, 4]);
      await context.call("save", { handle: open.handle, data: { tema: "a" } });
    }),
  );
  assert.deepEqual(await controller.processRecording("r", { baseVersionId: "v4" }), { versionId: "v6" });
  const derived = recording.versions[5];
  assert.deepEqual(
    [derived.sourceVersionId, derived.transcript.text, derived.data, derived.digest?.title, derived.inputs],
    ["v4", "cuarta", { tema: "a" }, "Resumen 1", plain],
  );
  assert.deepEqual(recording.versions[3], v4);
  assert.equal(recording.currentVersionId, "v6");
  assert.deepEqual(of("version_save").map((params) => params.select), [false]);
  assert.equal(of("version_update").some((params) => params.versionId === "v4"), false);
});

test("transcribir con hablantes sobre una versión conserva su resumen y sus datos y no hereda sus huellas", async () => {
  const v5 = version("v5", "cinco", { data: { tema: "b" }, digest: { title: "Resumen de la cinco", summary: "x", tags: [] } });
  const { host, recording, of } = library([version("v4", "cuatro"), v5], "v5");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("transcribe", { handle: open.handle, hablantes: { detectar: true } });
      await context.call("save", { handle: open.handle, data: { tema: "b" } });
    }),
  );
  await controller.processRecording("r");
  const derived = recording.versions[2];
  assert.deepEqual(
    [derived.sourceVersionId, derived.transcript.text, derived.digest?.title, derived.data, derived.inputs?.diarize],
    ["v5", "nueva 1", "Resumen de la cinco", { tema: "b" }, true],
  );
  assert.equal(of("version_save")[0].voicesFrom, null);
  assert.equal(recording.currentVersionId, "v3");
});

test("componer sobre la misma nota deja una sola versión con transcripción y resumen", async () => {
  const { host, recording, of } = library([version("v1", "uno")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("transcribe", { handle: open.handle, hablantes: { detectar: true } });
      await context.call("summarize", { handle: open.handle });
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  await controller.processRecording("r");
  assert.equal(of("version_save").length, 1);
  assert.deepEqual([recording.versions.length, recording.versions[1].digest?.title, recording.currentVersionId], [2, "Resumen 1", "v2"]);
});

test("guardar una nota sin cambios no crea versión ni cambia la vigente", async () => {
  const { host, recording, of } = library([version("v1", "uno"), version("v2", "dos")], "v2");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  assert.deepEqual(await controller.processRecording("r", { baseVersionId: "v1" }), { versionId: "v1" });
  assert.deepEqual([of("version_save"), of("version_select"), recording.currentVersionId], [[], [], "v2"]);
});

test("reprocesar a mano con los criterios de la versión de partida vuelve a transcribir una vez por ejecución y crea versión", async () => {
  const { host, recording, of, transcriptions, statuses } = library([version("v1", "original")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("transcribe", { handle: open.handle, stt: "local-stt", idioma: "es" });
      await context.call("transcribe", { handle: open.handle, stt: "local-stt", idioma: "es" });
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  await controller.processRecording("r", { force: true });
  assert.deepEqual([transcriptions(), of("version_save").length, recording.currentVersionId, statuses()], [1, 1, "v2", ["processing", "done"]]);
});

test("transcribir con los criterios de la versión de partida sin forzar devuelve la suya sin transcribir, sin crear versión ni pasar por procesando", async () => {
  const corrected = version("v2", "corregida", { backend: "correccion", sourceVersionId: "v1" } as Partial<Version>);
  const { host, of, transcriptions, statuses } = library([version("v1", "original"), corrected], "v2");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      const transcribed = (await context.call("transcribe", { handle: open.handle, stt: "local-stt", idioma: "es" })) as Note;
      assert.deepEqual([transcribed.texto, transcribed.version], ["corregida", 2]);
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  await controller.processRecording("r", { force: false });
  assert.deepEqual([transcriptions(), of("version_save").length, statuses()], [0, 0, []]);
});

test("una corrección antigua sin criterios se reconoce con los de su versión anterior y no se vuelve a transcribir", async () => {
  const legacy = version("v2", "corregida a mano", { backend: "correccion", inputs: undefined });
  const { host, of, transcriptions } = library([version("v1", "original"), legacy], "v2");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      const transcribed = (await context.call("transcribe", { handle: open.handle, stt: "local-stt", idioma: "es" })) as Note;
      assert.equal(transcribed.texto, "corregida a mano");
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  await controller.processRecording("r", { force: false });
  assert.deepEqual([transcriptions(), of("version_save").length], [0, 0]);
});

test("editar escribe en la propia versión, también su transcripción, sin crear otra", async () => {
  const { host, recording, of } = library([version("v1", "uno"), version("v2", "dos")], "v2");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const edited = await note(context, { version: "v1", editar: true });
      assert.deepEqual([edited.version, edited.origen], [1, 1]);
      await context.call("summarize", { handle: edited.handle });
      await context.call("transcribe", { handle: edited.handle, hablantes: { detectar: true } });
      await context.call("save", { handle: edited.handle, data: { listo: true } });
    }),
  );
  await controller.processRecording("r");
  assert.equal(of("version_save").length, 0);
  assert.deepEqual(
    [recording.versions.length, recording.versions[0].digest?.title, recording.versions[0].transcript.text, recording.versions[0].data, recording.currentVersionId],
    [2, "Resumen 1", "nueva 1", { listo: true }, "v1"],
  );
});

test("una receta puede pedir otra versión que no es la vigente y lista las versiones", async () => {
  const { host } = library([version("v1", "uno"), version("v2", "dos")], "v2");
  const seen: unknown[] = [];
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const versions = (await context.call("versions", {})) as Array<{ clave: string; numero: number; vigente: boolean; abierta: boolean }>;
      seen.push(versions.map((item) => [item.clave, item.numero, item.vigente, item.abierta]));
      const first = await note(context, { version: "v1" });
      seen.push([first.texto, first.version, first.origen]);
      await assert.rejects(note(context, { version: "otra" }), /no pertenece a la grabación/);
    }),
  );
  await controller.processRecording("r");
  assert.deepEqual(seen, [
    [
      ["v1", 1, false, false],
      ["v2", 2, true, true],
    ],
    ["uno", 1, 1],
  ]);
});

test("cada nota pedida aparte es su copia y su guardar su versión", async () => {
  const { host, recording } = library([version("v1", "uno"), version("v2", "dos")], "v2");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      for (const id of ["v1", "v2"]) {
        const copy = await note(context, { version: id });
        await context.call("summarize", { handle: copy.handle });
        await context.call("save", { handle: copy.handle, data: null });
      }
    }),
  );
  await controller.processRecording("r");
  assert.deepEqual(
    recording.versions.slice(2).map((item) => [item.sourceVersionId, item.transcript.text]),
    [
      ["v1", "uno"],
      ["v2", "dos"],
    ],
  );
});

test("la receta a la que se pasa la grabación escribe en la nota en curso", async () => {
  const { host, recording, of } = library([version("v1", "uno")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context, task) => {
      if (task.payload.builtin === "resumir") {
        const shared = await note(context);
        await context.call("summarize", { handle: shared.handle });
        return;
      }
      const open = await note(context);
      await context.call("transcribe", { handle: open.handle, hablantes: { detectar: true } });
      await context.call("process", { recipeId: "serie:resumir" });
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  await controller.processRecording("r", { recipeId: "serie:transcribir" });
  assert.equal(of("version_save").length, 1);
  assert.deepEqual([recording.versions[1].inputs?.diarize, recording.versions[1].digest?.title], [true, "Resumen 1"]);
});

test("sin guardar, la versión derivada queda creada pero no vigente", async () => {
  const { host, recording } = library([version("v1", "uno")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("summarize", { handle: open.handle });
    }),
  );
  await controller.processRecording("r");
  assert.deepEqual([recording.versions.length, recording.currentVersionId], [2, "v1"]);
});

test("un reintento parte de la misma versión y escribe en la que creó el intento anterior", async () => {
  const { host, recording, of, summaries } = library([version("v1", "uno"), version("v2", "dos")], "v1");
  let attempt = 0;
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      assert.equal(open.texto, "uno");
      await context.call("summarize", { handle: open.handle });
      if (++attempt === 1) throw new RuntimeError("LLM caído", "backend_unavailable");
      await context.call("save", { handle: open.handle, data: null });
    }),
  );
  const options = { baseVersionId: "v1", jobId: "trabajo-1", force: true };
  await assert.rejects(controller.processRecording("r", options), /LLM caído/);
  recording.currentVersionId = "v2";
  await controller.processRecording("r", { ...options, force: false });
  assert.deepEqual([recording.versions.length, of("version_save").length, recording.currentVersionId, summaries()], [3, 1, "v3", 1]);
});

test("el mismo texto con el mismo LLM no se vuelve a resumir aunque esté en otra versión", async () => {
  const { host, summaries } = library([version("v1", "igual"), version("v2", "igual")], "v2");
  const summarize = async (baseVersionId: string) =>
    createRuntime(
      host,
      runner(async (context) => {
        const open = await note(context);
        await context.call("summarize", { handle: open.handle });
        await context.call("save", { handle: open.handle, data: null });
      }),
    ).processRecording("r", { baseVersionId, force: false });
  await summarize("v1");
  await summarize("v2");
  assert.equal(summaries(), 1);
});

test("un reprocesado a mano rehace el resumen una vez y sus reintentos lo recuerdan", async () => {
  const { host, summaries } = library([version("v1", "texto")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("summarize", { handle: open.handle });
      await context.call("summarize", { handle: open.handle });
    }),
  );
  await controller.processRecording("r", { force: true, baseVersionId: "v1" });
  assert.equal(summaries(), 1);
  await controller.processRecording("r", { force: true, baseVersionId: "v1" });
  assert.equal(summaries(), 2);
  await controller.processRecording("r", { force: false, baseVersionId: "v1" });
  assert.equal(summaries(), 2);
});

test("la versión de partida que ya no existe hace fallar el trabajo", async () => {
  const { host } = library([version("v1", "uno")], "v1");
  const controller = createRuntime(host, runner(async (context) => note(context)));
  await assert.rejects(controller.processRecording("r", { baseVersionId: "borrada" }), /versión de partida ya no existe/);
});

test("al probar una receta la nota se lee y nada se guarda", async () => {
  const { host, of } = library([version("v1", "texto")], "v1");
  const controller = createRuntime(
    host,
    runner(async (context) => {
      const open = await note(context);
      await context.call("summarize", { handle: open.handle });
      await context.call("save", { handle: open.handle, data: { x: 1 } });
    }),
  );
  await controller.processRecording("r", { dryRun: true });
  assert.deepEqual([...of("version_save"), ...of("version_update"), ...of("version_select"), ...of("memory_keep")], []);
});

test("cada receta de serie llega al worker con su programa, también sus variantes", async () => {
  const { state, host } = library([version("v1", "texto")], "v1");
  state.recipes.push({ id: "variante", name: "Resumir con otro", kind: "form", builtin: "resumir", values: { prompt: "Corto" } });
  const tasks: WorkerTask[] = [];
  const controller = createRuntime(host, runner(async (context) => note(context), tasks));
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
  const controller = createRuntime(host, runner(async (context) => note(context), tasks));
  await controller.processRecording("r", { recipeId: "ejemplo" });
  assert.deepEqual([tasks[0].program, tasks[0].payload.builtin], ["var __recipe={}", undefined]);
});

test("una receta que no transcribe no cambia el estado de una nota transcrita, ni al terminar ni al fallar", async () => {
  const { host, statuses } = library([version("v1", "texto")], "v1");
  await createRuntime(host, runner(async (context) => note(context))).processRecording("r");
  const failing = createRuntime(
    host,
    runner(async (context) => {
      await note(context);
      throw Error("LLM caído");
    }),
  );
  await assert.rejects(failing.processRecording("r"), /LLM caído/);
  assert.deepEqual(statuses(), []);
});

test("transcribir lleva la nota por procesando hasta terminada, y una nota sin versión empieza procesando", async () => {
  const transcribed = library([version("v1", "texto")], "v1");
  await createRuntime(
    transcribed.host,
    runner(async (context) => context.call("transcribe", { hablantes: { detectar: true } })),
  ).processRecording("r");
  assert.deepEqual(transcribed.statuses(), ["processing", "done"]);
  const empty = library();
  await assert.rejects(createRuntime(empty.host, runner(async (context) => note(context))).processRecording("r"), /no produjo/);
  assert.deepEqual(empty.statuses(), ["processing", "failed"]);
});
