import { buildBuiltinRecipes } from "../../runtime-host/defaultRecipe.mjs";
import { beforeAll, test } from "vitest";
import assert from "node:assert/strict";
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  createWorkerRunner,
  type WorkerPort,
} from "../../src/runtime/workerClient";
const root = fileURLToPath(new URL("../../../../", import.meta.url));
let workerCode = "";
beforeAll(async () => {
  const built = await build({
    entryPoints: [`${root}apps/tauri/src/runtime/worker.ts`],
    define: { __BUILTIN_RECIPES__: JSON.stringify(await buildBuiltinRecipes()) },
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    alias: { "@escriba/conectores": `${root}packages/conectores/src/index.ts` },
    nodePaths: [`${root}apps/tauri/node_modules`],
  });
  workerCode = built.outputFiles[0].text;
});
function runner() {
  return createWorkerRunner(() => {
    const worker = new Worker(
      `const {parentPort}=require('node:worker_threads');globalThis.postMessage=(data)=>parentPort.postMessage(data);parentPort.on('message',data=>globalThis.onmessage({data}));${workerCode}`,
      { eval: true },
    );
    const port: WorkerPort = {
      postMessage: (value) => worker.postMessage(value),
      terminate: () => {
        void worker.terminate();
      },
      onmessage: null,
      onerror: null,
      onmessageerror: null,
    };
    worker.on("message", (data) => port.onmessage?.({ data } as MessageEvent));
    worker.on("error", (error) =>
      port.onerror?.({ message: error.message } as ErrorEvent),
    );
    return port;
  });
}
async function recipe(source: string) {
  const built = await build({
    stdin: { contents: source, resolveDir: `${root}apps/tauri` },
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    globalName: "__recipe",
    nodePaths: [`${root}apps/tauri/node_modules`],
  });
  return built.outputFiles[0].text;
}
const lists = {
  stts: [{ clave: "local-stt", nombre: "Whisper", local: true }],
  llms: [{ clave: "local-llm", nombre: "Apple", local: true }],
  conectores: [],
  recetas: [],
};
const payload = {
  audio: { clave: "r", nombre: "Nota", fecha: "2026-10-09" },
  lists,
  values: {},
};
test("una receta usa el SDK de Notion con la cuenta sin recibir su credencial", async () => {
  const program = await recipe(`import {Client} from '@notionhq/client';
    export async function flujo(audio,escriba) {
      const cuenta = escriba.cuenta('Trabajo');
      if ('token' in cuenta || 'credential' in cuenta) throw Error('secreto expuesto');
      const notion = new Client({fetch:cuenta.fetch});
      await notion.users.list({page_size:1});
      await notion.pages.create({parent:{page_id:'parent'},properties:{title:{title:[]}}});
    }`);
  const calls: Array<{ operation: string; args: unknown }> = [];
  await runner().run({ kind: "recipe", program, payload: {
    ...payload, lists: { ...lists, cuentas: [{ clave: "notion-1", nombre: "Trabajo", tipo: "notion", activo: true, origen: "https://api.notion.com" }] },
  } }, { call: async (operation, args) => {
    calls.push({ operation, args });
    return { status: 200, headers: { "content-type": "application/json" }, body: '{"object":"list","results":[],"has_more":false,"next_cursor":null}' };
  } });
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.equal(call.operation, "account.http");
    assert.equal((call.args as { accountId: string }).accountId, "notion-1");
  }
  assert.equal((calls[0].args as { method: string }).method, "GET");
  assert.equal((calls[1].args as { method: string }).method, "POST");
  assert.match((calls[1].args as { body: string }).body, /parent/);
});
test("Worker real valida Zod, pregunta y guarda datos sin acceso a red", async () => {
  const program = await recipe(
    `import {z} from 'zod'; export const receta={datos:z.object({tema:z.string()})}; export async function flujo(audio,api){if(typeof fetch!=='undefined'||typeof XMLHttpRequest!=='undefined')throw Error('red disponible');const note=await api.transcribir(audio);note.datos=await api.preguntar({entrada:note.texto,esquema:z.object({tema:z.string()})});await note.guardar();}`,
  );
  const calls: string[] = [];
  await runner().run(
    { kind: "recipe", program, payload },
    {
      call: async (op, args) => {
        calls.push(op);
        if (op === "transcribe")
          return {
            handle: "v1",
            clave: "r",
            version: 1,
            texto: "Texto",
            segmentos: [],
            datos: null,
          };
        if (op === "ask") {
          assert.equal(
            (args as { schema: { type: string } }).schema.type,
            "object",
          );
          return { tema: "Acuerdo" };
        }
        if (op === "save") {
          assert.deepEqual((args as { data: unknown }).data, {
            tema: "Acuerdo",
          });
          return {
            handle: "v1",
            clave: "r",
            version: 1,
            texto: "Texto",
            datos: { tema: "Acuerdo" },
          };
        }
        throw Error(`unexpected ${op}`);
      },
    },
  );
  assert.deepEqual(calls, ["transcribe", "ask", "save"]);
});
test("sin programa de proyecto el worker ejecuta la receta por defecto compilada", async () => {
  const calls: Array<{ operation: string; args: Record<string, unknown> }> = [];
  const note = { handle: "v1", clave: "r", version: 1, texto: "Texto", segmentos: [], datos: null };
  await runner().run(
    { kind: "recipe", payload: { ...payload, lists: { ...lists, conectores: [{ clave: "okf", nombre: "Archivo", activo: true }, { clave: "notion", nombre: "Notion", activo: true }] }, values: { conectores: ["okf", "notion"] } } },
    {
      call: async (operation, args) => {
        calls.push({ operation, args: args as Record<string, unknown> });
        if (operation === "note" || operation === "transcribe" || operation === "save") return note;
        if (operation === "summarize") throw Error("motor ocupado");
        if (operation === "publish" && (args as { destinationId: string }).destinationId === "okf") throw Error("carpeta ausente");
        return null;
      },
    },
  );
  assert.deepEqual(calls.filter((call) => call.operation !== "log").map((call) => call.operation), ["note", "transcribe", "summarize", "save", "publish", "publish"]);
  assert.deepEqual(calls[1].args, { stt: "local-stt", idioma: "es", hablantes: { detectar: false, cuantos: null }, handle: "v1" });
  assert.deepEqual(calls.filter((call) => call.operation === "publish").map((call) => call.args.destinationId), ["okf", "notion"]);
  const warnings = calls.filter((call) => call.operation === "log").map((call) => call.args);
  assert.ok(warnings.every((entry) => entry.level === "warn"), JSON.stringify(warnings));
  assert.match(String(warnings[0].message), /resumir.*motor ocupado/);
  assert.match(String(warnings[1].message), /okf.*carpeta ausente/);
});
test("el formulario por defecto sale del programa compilado con el idioma de los ajustes", async () => {
  const schema = (await runner().run(
    { kind: "recipe-schema", payload: { lists, defaultLanguage: "en" } },
    { call: async () => null },
  )) as { properties: Record<string, { default?: unknown }> };
  assert.equal(schema.properties.idioma.default, "en");
  assert.equal(schema.properties.resumir.default, true);
  assert.deepEqual(Object.keys(schema.properties), ["stt", "idioma", "hablantes", "resumir", "llm", "prompt", "conectores"]);
});
function recording(results: (operation: string, args: Record<string, unknown>) => unknown) {
  const calls: Array<{ operation: string; args: Record<string, unknown> }> = [];
  return {
    calls,
    operations: () => calls.filter((call) => call.operation !== "log").map((call) => call.operation),
    call: async (operation: string, args: unknown) => {
      calls.push({ operation, args: args as Record<string, unknown> });
      return results(operation, args as Record<string, unknown>);
    },
  };
}
const vigente = { handle: "v2", clave: "r", version: 2, origen: 2, texto: "Texto", segmentos: [], datos: null };
const vacia = { handle: "n1", clave: "r", version: null, origen: null, texto: "", segmentos: [], datos: null };
const conectores = [{ clave: "okf", nombre: "Archivo", activo: true }, { clave: "notion", nombre: "Notion", activo: true }];
test("Transcribir de serie transcribe la nota abierta con sus valores y guarda sin resumir ni publicar", async () => {
  const host = recording(() => vigente);
  await runner().run({ kind: "recipe", payload: { ...payload, builtin: "transcribir", values: { idioma: "en", hablantes: { detectar: true } } } }, host);
  assert.deepEqual(host.operations(), ["note", "transcribe", "save"]);
  assert.deepEqual(host.calls[1].args, { stt: "local-stt", idioma: "en", hablantes: { detectar: true, cuantos: null }, handle: "v2" });
});
test("Resumir de serie resume la nota vigente con su LLM y su prompt sin transcribir", async () => {
  const host = recording(() => vigente);
  const llms = [...lists.llms, { clave: "remoto", nombre: "Remoto", local: false }];
  await runner().run({ kind: "recipe", payload: { ...payload, builtin: "resumir", lists: { ...lists, llms }, values: { llm: "remoto", prompt: "Breve" } } }, host);
  assert.deepEqual(host.operations(), ["note", "summarize", "save"]);
  assert.deepEqual(host.calls[1].args, { llm: "remoto", prompt: "Breve", handle: "v2" });
});
test("Resumir y Publicar de serie fallan sin tocar nada si la nota no está transcrita", async () => {
  for (const builtin of ["resumir", "publicar"]) {
    const host = recording(() => vacia);
    await assert.rejects(
      runner().run({ kind: "recipe", payload: { ...payload, builtin, lists: { ...lists, conectores }, values: builtin === "publicar" ? { conectores: ["okf"] } : {} } }, host),
      /La nota aún no está transcrita/,
    );
    assert.deepEqual(host.operations(), ["note"]);
  }
});
test("Publicar de serie intenta todos sus conectores sobre la vigente y falla si alguno falla", async () => {
  const host = recording((operation, args) => {
    if (operation === "publish" && args.destinationId === "okf") throw Error("carpeta ausente");
    return operation === "publish" ? null : vigente;
  });
  await assert.rejects(
    runner().run({ kind: "recipe", payload: { ...payload, builtin: "publicar", lists: { ...lists, conectores }, values: { conectores: ["okf", "notion"] } } }, host),
    /carpeta ausente/,
  );
  assert.deepEqual(host.operations(), ["note", "save", "publish", "publish"]);
  assert.deepEqual(host.calls.filter((call) => call.operation === "publish").map((call) => [call.args.destinationId, call.args.handle]), [["okf", "v2"], ["notion", "v2"]]);
});
test("cada receta de serie tiene su formulario y solo «Por defecto» condiciona el resumen", async () => {
  const schema = async (builtin: string) =>
    (await runner().run({ kind: "recipe-schema", payload: { lists, builtin, defaultLanguage: "en" } }, { call: async () => null })) as {
      properties: Record<string, { default?: unknown; si?: unknown }>;
    };
  const transcribir = await schema("transcribir");
  assert.deepEqual(Object.keys(transcribir.properties), ["stt", "idioma", "hablantes"]);
  assert.equal(transcribir.properties.idioma.default, "en");
  const resumir = await schema("resumir");
  assert.deepEqual(Object.keys(resumir.properties), ["llm", "prompt"]);
  assert.equal(resumir.properties.llm.si, undefined);
  assert.deepEqual(Object.keys((await schema("publicar")).properties), ["conectores"]);
  assert.equal((await schema("por-defecto")).properties.llm.si, "resumir");
});
test("una receta de serie desconocida falla nombrándola", async () => {
  await assert.rejects(
    runner().run({ kind: "recipe-schema", payload: { lists, builtin: "traducir" } }, { call: async () => null }),
    /Receta de serie desconocida: traducir/,
  );
});
test("escriba.nota devuelve la nota de su grabación, vacía si nunca se transcribió, y rechaza otro audio", async () => {
  const program = await recipe(`export async function flujo(audio, escriba) {
    const nota = await escriba.nota(audio);
    console.log(nota.version === null ? "sin transcribir" : nota.texto);
    await escriba.nota({ ...audio });
  }`);
  for (const [answer, logged] of [[vigente, "Texto"], [vacia, "sin transcribir"]] as const) {
    const host = recording(() => answer);
    await assert.rejects(runner().run({ kind: "recipe", program, payload }, host), /su grabación/);
    assert.deepEqual(host.operations(), ["note"]);
    assert.equal(host.calls.find((call) => call.operation === "log")?.args.message, logged);
  }
});
test("una receta pide otra versión para editarla, lista las versiones y transcribe sobre su nota", async () => {
  const program = await recipe(`export async function flujo(audio, escriba) {
    const [primera] = await escriba.versiones(audio);
    const nota = await escriba.nota(audio, { version: primera.clave, editar: true });
    await nota.transcribir({ idioma: "es" });
    await nota.guardar();
  }`);
  const host = recording((operation) => (operation === "versions" ? [{ clave: "v1", numero: 1 }] : vigente));
  await runner().run({ kind: "recipe", program, payload }, host);
  assert.deepEqual(host.operations(), ["versions", "note", "transcribe", "save"]);
  assert.deepEqual([host.calls[1].args, host.calls[2].args], [{ version: "v1", editar: true }, { idioma: "es", handle: "v2" }]);
});
test("pedir la misma nota dos veces devuelve el mismo objeto y conserva sus datos sin guardar", async () => {
  const program = await recipe(`export async function flujo(audio, escriba) {
    const nota = await escriba.nota(audio);
    nota.datos = { tema: "a" };
    const otra = await escriba.transcribir(audio);
    if (otra !== nota || otra.datos.tema !== "a") throw Error("nota duplicada");
    await otra.guardar();
  }`);
  const host = recording(() => vigente);
  await runner().run({ kind: "recipe", program, payload }, host);
  assert.deepEqual(host.calls.find((call) => call.operation === "save")?.args, { handle: "v2", data: { tema: "a" } });
});
test("una receta que declara partir de una nota lo dice al inspeccionarla", async () => {
  const program = await recipe(`export const receta = { nombre: "Solo notas", parte: "nota" }; export async function flujo() {}`);
  const inspected = (await runner().run({ kind: "recipe-inspect", program, payload: { lists } }, { call: async () => null })) as Record<string, unknown>;
  assert.deepEqual([inspected.name, inspected.startsFrom], ["Solo notas", "note"]);
});
test("una receta de código sin formulario comunica que no tiene parámetros", async () => {
  const schema = await runner().run(
    { kind: "recipe-schema", program: "var __recipe={flujo(){}}", payload: { lists } },
    { call: async () => { throw Error("Leer el formulario no usa capacidades"); } },
  );
  assert.equal(schema, null);
});

test("Worker real se termina por timeout y cancelación incluso con bucle CPU", async () => {
  const program = "var __recipe={flujo(){while(true){}}}";
  await assert.rejects(
    runner().run(
      { kind: "recipe", program, payload },
      { timeoutMs: 100, call: async () => null },
    ),
    /tiempo permitido/,
  );
  const abort = new AbortController();
  const pending = runner().run(
    { kind: "recipe", program, payload },
    { signal: abort.signal, timeoutMs: 3000, call: async () => null },
  );
  setTimeout(() => abort.abort(), 50);
  await assert.rejects(pending, /cancelado/);
});
test("Worker real rechaza publicar una nota ajena", async () => {
  const program =
    'var __recipe={async flujo(audio,api){await api.conector("d").publicar({})}}';
  await assert.rejects(
    runner().run(
      {
        kind: "recipe",
        program,
        payload: {
          ...payload,
          lists: { ...lists, conectores: [{ clave: "d", nombre: "Destino" }] },
        },
      },
      {
        call: async () => {
          throw Error("no debe acceder host");
        },
      },
    ),
    /nota de esta ejecución/,
  );
});
test("formulario original empaquetado conserva campos y valores predeterminados", async () => {
  const built = await build({
    entryPoints: [`${root}recetas/por-defecto/receta.ts`],
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    globalName: "__recipe",
    nodePaths: [`${root}apps/tauri/node_modules`],
  });
  const schema = (await runner().run(
    {
      kind: "recipe-schema",
      program: built.outputFiles[0].text,
      payload: { lists },
    },
    {
      call: async () => {
        throw Error("inspección sin host");
      },
    },
  )) as { properties: Record<string, unknown> };
  assert.deepEqual(Object.keys(schema.properties), [
    "stt",
    "idioma",
    "hablantes",
    "resumir",
    "llm",
    "prompt",
    "conectores",
  ]);
});
test("SDK Notion real en Worker transmite audio opaco por rangos y checkpoint antes del resultado", async () => {
  const ranges: unknown[] = [];
  const checkpoints: unknown[] = [];
  const paths: string[] = [];
  const result = (await runner().run(
    {
      kind: "connector",
      payload: {
        operation: "publish",
        provider: "notion",
        config: {
          source: {
            id: "s",
            title: "Notas",
            properties: [{ name: "Nombre", type: "title" }],
          },
          columns: { Nombre: "{{titulo}}" },
          body: "{{audio}}",
        },
        note: {
          key: "r",
          startedAt: "2026-10-09T10:00:00Z",
          text: "Texto",
          segments: [],
          source: "urn:escriba:recording:r",
          timeZone: "UTC",
        },
        now: "2026-10-09T10:00:00Z",
      },
    },
    {
      call: async (op, raw) => {
        const args = raw as Record<string, unknown>;
        if (op === "connector.audio")
          return {
            size: 21 * 1024 * 1024,
            type: "audio/mp4",
            filename: "note.m4a",
          };
        if (op === "connector.checkpoint") {
          checkpoints.push(args.receipt);
          return null;
        }
        if (op === "connector.http") {
          assert.ok(
            Object.keys(args.headers as object).every((h) =>
              ["content-type", "notion-version"].includes(h),
            ),
          );
          const path = String(args.url);
          paths.push(path);
          if (Array.isArray(args.multipart))
            for (const part of args.multipart)
              if (part.audio) ranges.push(part.audio);
          return {
            status: 200,
            headers: { "content-type": "application/json" },
            body: JSON.stringify(
              path.endsWith("/file_uploads")
                ? { id: "upload-1" }
                : path.endsWith("/pages")
                  ? { id: "page-1", url: "https://notion.so/fake" }
                  : {},
            ),
          };
        }
        throw Error(`unexpected ${op}`);
      },
    },
  )) as { receipt: { locator: string } };
  assert.equal(result.receipt.locator, "page-1");
  assert.deepEqual(ranges, [
    { start: 0, end: 10 * 1024 * 1024 },
    { start: 10 * 1024 * 1024, end: 20 * 1024 * 1024 },
    { start: 20 * 1024 * 1024, end: 21 * 1024 * 1024 },
  ]);
  assert.ok(
    checkpoints.some(
      (value) => (value as { locator?: string }).locator === "page-1",
    ),
  );
  assert.ok(paths.some((path) => path.endsWith("/complete")));
});
test("SDK y host de capacidades se integran sin cabeceras fuera del permiso", async () => {
  const { createConnectorService } = await import(
    "../../src/runtime/connectors"
  );
  const { snapshot, runtimeContext } = await import("./fixture");
  const state = structuredClone(snapshot);
  state.accounts.push({
    id: "a",
    name: "Notion",
    provider: "notion",
    enabled: true,
    origin: "https://api.notion.com",
  });
  state.destinations.push({
    id: "d",
    name: "Notas",
    provider: "notion",
    account: "a",
    enabled: true,
    configuration: {},
  });
  let requests = 0;
  const service = createConnectorService(
    {
      call: async (method, params = {}) => {
        if (method === "runtime_context") return runtimeContext(state, params.recordingId);
        if (method === "connector_http") {
          requests++;
          return {
            status: 200,
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              results: [],
              has_more: false,
              next_cursor: null,
            }),
          };
        }
        throw Error(`unexpected ${method}`);
      },
    },
    runner(),
  );
  assert.deepEqual(await service.discover("d"), { resources: [] });
  assert.equal(requests, 1);
});
test("idioma de ajustes rige formulario builtin sin pisar explícito ni formulario de usuario", async () => {
  const { createRuntime } = await import("../../src/runtime/controller");
  const { snapshot, runtimeContext } = await import("./fixture");
  const state = structuredClone(snapshot);
  state.settings.language = "en";
  state.recipes[0].values = { resumir: false };
  const languages: unknown[] = [];
  const runtime = createRuntime(
    {
      call: async (method, params = {}) => {
        if (method === "runtime_context") return runtimeContext(state, params.recordingId);
        if (method === "transcribe") {
          languages.push(params.language);
          return { text: "Texto", segments: [] };
        }
        if (method === "version_save")
          return { ...params, id: crypto.randomUUID(), createdAt: "now" };
        return null;
      },
    },
    runner(),
  );
  const schema = (await runtime.getRecipeSchema("default")) as {
    properties: { idioma: { default: unknown } };
  };
  assert.equal(schema.properties.idioma.default, "en");
  await runtime.processRecording("r");
  state.settings.language = "auto";
  const autoSchema = (await runtime.getRecipeSchema("default")) as {
    properties: { idioma: { default: unknown } };
  };
  assert.equal(autoSchema.properties.idioma.default, null);
  await runtime.processRecording("r");
  state.recipes[0].values.idioma = "es";
  await runtime.processRecording("r");
  state.recipes[0].values.idioma = null;
  await runtime.processRecording("r");
  state.recipes[0].kind = "code";
  state.recipes[0].values = {};
  state.recipes[0].bundle = await recipe(
    `import {z} from 'zod';export function buildRecipeForm(){return z.object({idioma:z.literal('en').default('en')})}export async function flujo(audio,api){await (await api.transcribir(audio,{idioma:api.parametros.idioma})).guardar()}`,
  );
  await runtime.processRecording("r");
  assert.deepEqual(languages, ["en", null, "es", null, "en"]);
});
test("reprocesar usa los parámetros puntuales y la siguiente ejecución conserva los guardados", async () => {
  const { createRuntime } = await import("../../src/runtime/controller");
  const { snapshot, runtimeContext } = await import("./fixture");
  const state = structuredClone(snapshot);
  state.recipes[0].values = { idioma: "en", resumir: false };
  const languages: unknown[] = [];
  const runtime = createRuntime({
    call: async (method, params = {}) => {
      if (method === "runtime_context") return runtimeContext(state, params.recordingId);
      if (method === "transcribe") {
        languages.push(params.language);
        return { text: "Texto sintético", segments: [] };
      }
      if (method === "version_save")
        return { ...params, id: crypto.randomUUID(), createdAt: "now" };
      if (["recording_update", "version_update", "version_select", "log", "trace_save", "memory_recall", "memory_keep"].includes(method)) return null;
      throw Error(`Capacidad inesperada: ${method}`);
    },
  }, runner());

  await runtime.processRecording("r", { values: { idioma: "es", resumir: false } });
  await runtime.processRecording("r");
  assert.deepEqual(languages, ["es", "en"]);
  assert.deepEqual(state.recipes[0].values, { idioma: "en", resumir: false });
});

test("tiempo de inferencia en host no consume presupuesto CPU de la receta", async () => {
  const program =
    "var __recipe={async flujo(audio,api){await(await api.transcribir(audio)).guardar()}}";
  await runner().run(
    { kind: "recipe", program, payload },
    {
      timeoutMs: 300,
      call: async (op) => {
        if (op === "transcribe")
          await new Promise((resolve) => setTimeout(resolve, 450));
        return {
          handle: "v1",
          clave: "r",
          version: 1,
          texto: "Texto",
          segmentos: [],
          datos: null,
        };
      },
    },
  );
});
test("el presupuesto activo se acumula entre llamadas al host", async () => {
  const program =
    "var __recipe={async flujo(audio,api){for(let i=0;i<4;i++){const until=performance.now()+100;while(performance.now()<until){}await api.transcribir(audio);}}}";
  await assert.rejects(
    runner().run(
      { kind: "recipe", program, payload },
      {
        timeoutMs: 300,
        call: async () => {
          await new Promise((resolve) => setTimeout(resolve, 20));
          return {
            handle: "v1",
            clave: "r",
            version: 1,
            texto: "Texto",
            segmentos: [],
            datos: null,
          };
        },
      },
    ),
    /tiempo permitido/,
  );
});

test("una receta usa el AI SDK con escriba.modelo o por nombre, con herramientas y sin red ni claves", async () => {
  const program = await recipe(`import { generateText, streamText, tool, stepCountIs } from "ai"; import { z } from "zod";
    export async function flujo(audio, escriba) {
      if (typeof fetch !== "undefined") throw Error("red disponible");
      const conHerramienta = await generateText({ model: escriba.modelo("Claude"), prompt: "¿Cuántas letras?", stopWhen: stepCountIs(3),
        tools: { contar: tool({ description: "cuenta", inputSchema: z.object({ texto: z.string() }), execute: async ({ texto }) => ({ letras: texto.length }) }) } });
      const porNombre = await generateText({ model: "Claude", prompt: "hola" });
      const enStream = streamText({ model: escriba.modelo("remoto"), prompt: "hola" });
      escriba.log(JSON.stringify([conHerramienta.text, conHerramienta.steps.length, porNombre.text, await enStream.text]));
    }`);
  const requests: Record<string, unknown>[] = [];
  const logs: string[] = [];
  const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
  const text = (value: string) => ({ content: [{ type: "text", text: value }], finishReason: { unified: "stop", raw: "stop" }, usage, warnings: [] });
  await runner().run(
    { kind: "recipe", program, payload: { ...payload, lists: { ...lists, llms: [...lists.llms, { clave: "remoto", nombre: "Claude", local: false }] } } },
    {
      call: async (op, args) => {
        if (op === "log") {
          logs.push(String((args as { message: unknown }).message));
          return null;
        }
        assert.equal(op, "model");
        const request = args as { llm: string; method: string; options: Record<string, unknown> };
        requests.push(request);
        assert.equal(request.llm, "remoto");
        assert.equal("abortSignal" in request.options || "headers" in request.options, false);
        if (request.method === "doStream")
          return { parts: [{ type: "stream-start", warnings: [] }, { type: "text-start", id: "1" }, { type: "text-delta", id: "1", delta: "en stream" }, { type: "text-end", id: "1" }, { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage }] };
        if (requests.length === 1)
          return { content: [{ type: "tool-call", toolCallId: "1", toolName: "contar", input: JSON.stringify({ texto: "hola" }) }], finishReason: { unified: "tool-calls", raw: "tool_calls" }, usage, warnings: [] };
        if (requests.length === 2) {
          const tool = (request.options.prompt as { role: string; content: { type: string; output?: unknown }[] }[]).find((message) => message.role === "tool");
          assert.deepEqual(tool?.content[0]?.output, { type: "json", value: { letras: 4 } });
          return text("cuatro letras");
        }
        return text("por nombre");
      },
    },
  );
  assert.deepEqual(requests.map((request) => request.method), ["doGenerate", "doGenerate", "doGenerate", "doStream"]);
  assert.ok(logs.some((line) => line.includes('["cuatro letras",2,"por nombre","en stream"]')), logs.join("\n"));
});
