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
