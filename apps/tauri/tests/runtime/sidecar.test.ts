import { once } from "node:events";
import { beforeAll, afterAll, test } from "vitest";
import assert from "node:assert/strict";
import {
  spawn,
  spawnSync,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { cp, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { connect, createServer } from "node:net";
import { createServer as createHttpServer, type IncomingHttpHeaders, type IncomingMessage } from "node:http";
import { build } from "esbuild";
import { CborCodec, RecordId } from "surrealdb";
import { controllerEnvironment } from "./native";
import type { Recipe, Recording, Snapshot } from "../../src/types";
// macOS isolates with sandbox-exec and Linux with escriba-sandbox, as in the app.
const macos = process.platform === "darwin";
const linux = process.platform === "linux";
const windows = process.platform === "win32";
const isolation = test.runIf(macos || linux || windows);
let directory = "";
let executable = "";
let sandbox = "";
beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "escriba-runtime-"));
  executable = join(directory, process.platform === "win32" ? "runtime.exe" : "runtime");
  const build = fileURLToPath(
    new URL("../../runtime-host/build.mjs", import.meta.url),
  );
  const result = spawnSync(process.execPath, [build, executable], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  if (linux || windows) {
    const manifest = fileURLToPath(new URL("../../sandbox/Cargo.toml", import.meta.url));
    const cargo = spawnSync("cargo", ["build", "--release", "--quiet", "--bin", "escriba-sandbox", "--manifest-path", manifest], { encoding: "utf8" });
    assert.equal(cargo.status, 0, cargo.stderr);
    sandbox = fileURLToPath(new URL(`../../sandbox/target/release/escriba-sandbox${windows ? ".exe" : ""}`, import.meta.url));
  }
}, 120000);
afterAll(async () => {
  await rm(directory, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 });
});
function launch(data: string, worker = false) {
  const path = realpathSync(executable);
  if (!worker) return spawn(path, [], { env: controllerEnvironment(data), cwd: tmpdir() });
  if (linux || windows) return spawn(sandbox, ["worker", "--executable", path, "--", "--worker"], { env: windows ? { SystemRoot: process.env.SystemRoot, LOCALAPPDATA: process.env.LOCALAPPDATA } : {}, cwd: tmpdir() });
  if (!macos) return spawn(path, ["--worker"], { env: windows ? { SystemRoot: process.env.SystemRoot, LOCALAPPDATA: process.env.LOCALAPPDATA } : {}, cwd: tmpdir() });
  const profile = readFileSync(new URL("../../runtime-host/sandbox.sb", import.meta.url), "utf8");
  return spawn("/usr/bin/sandbox-exec", [
    "-p", profile, "-D", `EXECUTABLE=${path}`, path, "--worker",
  ], { env: windows ? { SystemRoot: process.env.SystemRoot, LOCALAPPDATA: process.env.LOCALAPPDATA } : {}, cwd: tmpdir() });
}
function localHttp(handle: (request: IncomingMessage, body: string) => { status: number; body: string }) {
  const seen: { method: string; url: string; headers: IncomingHttpHeaders; body: string }[] = [];
  const server = createHttpServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      seen.push({ method: request.method ?? "", url: request.url ?? "", headers: request.headers, body });
      const reply = handle(request, body);
      response.writeHead(reply.status, { "content-type": "application/json" });
      response.end(reply.body);
    });
  });
  return new Promise<{ origin: string; seen: typeof seen; close(): void }>((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({ origin: `http://127.0.0.1:${port}`, seen, close: () => server.close() });
    });
  });
}
const FORM_RECIPE: Recipe = { id: "default", name: "Por defecto", kind: "form", values: { resumir: false } };
interface Options {
  data?: string;
  hangFirstTranscribe?: boolean;
  capability?: (method: string, params: Record<string, unknown>) => Promise<unknown>;
}
function supervisor(options: Options = {}) {
  const data = options.data ?? mkdtempSync(join(directory, "data-"));
  let hung = false;
  const child = launch(data);
  const workers = new Map<string, ChildProcessWithoutNullStreams>();
  const pending = new Map<
    string,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  const methods: string[] = [];
  const nativeMethods: string[] = [];
  const calls: { method: string; native?: string; taskId: unknown }[] = [];
  const events: { event: string; value: unknown }[] = [];
  let readyResolve!: () => void;
  let readyReject!: (error: Error) => void;
  const ready = new Promise<void>((resolve, reject) => {
    readyResolve = resolve;
    readyReject = reject;
  });
  let counter = 0;
  let stderr = "";
  child.stderr.on("data", (v) => {
    stderr += v;
  });
  const send = (value: unknown) =>
    child.stdin.write(`${JSON.stringify(value)}\n`);
  const frames = createInterface({ input: child.stdout });
  frames.on("line", async (line) => {
    const value = JSON.parse(line);
    const id = String(value.id);
    if (value.type === "ready") {
      assert.equal(value.protocolVersion, 1);
      readyResolve();
      return;
    }
    if (value.type === "worker_create") {
      const worker = launch(data, true);
      workers.set(id, worker);
      createInterface({ input: worker.stdout }).on("line", (output) => {
        try {
          send({ type: "worker_message", id, value: JSON.parse(output) });
        } catch {
          send({
            type: "worker_error",
            id,
            message: "worker emitió JSON inválido",
          });
        }
      });
      worker.stderr.on("data", () => {});
      worker.on("exit", (code) => {
        if (workers.delete(id))
          send({
            type: "worker_error",
            id,
            message: `worker terminó: ${code}`,
          });
      });
      return;
    }
    if (value.type === "worker_send") {
      workers.get(id)?.stdin.write(`${JSON.stringify(value.value)}\n`);
      return;
    }
    if (value.type === "worker_terminate") {
      const worker = workers.get(id);
      workers.delete(id);
      worker?.kill("SIGKILL");
      return;
    }
    if (value.type === "event") {
      events.push({ event: value.event, value: value.value });
      return;
    }
    if (value.type === "result" || value.type === "error") {
      const waiter = pending.get(id);
      pending.delete(id);
      if (value.type === "error") waiter?.reject(Error(value.message));
      else waiter?.resolve(value.value);
      return;
    }
    if (value.type === "call") {
      methods.push(value.method);
      const params = value.params as Record<string, unknown>;
      calls.push({ method: value.method, ...(value.method === "shell.native" ? { native: String(params.method) } : {}), taskId: value.taskId });
      let result: unknown = null;
      if (value.method === "shell.native") {
        const native = String(params.method);
        nativeMethods.push(native);
        if (native === "status") result = { protocolVersion: 1, whisper: { available: true }, llm: { available: true } };
        else if (native === "transcribe") {
          if (options.hangFirstTranscribe && !hung) {
            hung = true;
            return;
          }
          result = { text: "Texto preservado", segments: [] };
        } else if (native === "summarize") result = { title: "Título", summary: "Resumen sintético", tags: [] };
        else {
          send({ type: "reject", id, message: `Método nativo no esperado ${native}` });
          return;
        }
      } else if (!["shell.native_cancel", "shell.notify", "shell.autolaunch", "shell.validate_catalog"].includes(value.method)) {
        if (!options.capability) {
          send({ type: "reject", id, message: `Capacidad no esperada ${value.method}` });
          return;
        }
        try {
          result = await options.capability(value.method, params);
        } catch (error) {
          send({ type: "reject", id, message: String(error) });
          return;
        }
      }
      send({ type: "resolve", id, value: result });
    }
  });
  child.on("exit", (code) => {
    readyReject(Error(`sidecar ${code}: ${stderr}`));
    for (const waiter of pending.values())
      waiter.reject(Error(`sidecar ${code}: ${stderr}`));
  });
  function command<T = unknown>(method: string, params: Record<string, unknown> = {}, origin: "ui" | "shell" = "ui") {
    const id = `command-${++counter}`;
    const result = new Promise<T>((resolve, reject) =>
      pending.set(id, { resolve: (value) => resolve(value as T), reject }),
    );
    send({ type: "command", id, method, params, origin });
    return result;
  }
  const host = {
    data,
    ready,
    methods,
    nativeMethods,
    calls,
    events,
    command,
    run: <T = unknown>(operation: string, args: Record<string, unknown>) => command<T>("runtime_run", { operation, args }),
    cancel: (recordingId: string) => command("runtime_cancel", { recordingId }),
    async drain() {
      for (let attempt = 0; attempt < 500; attempt++) {
        if (!(await command<unknown[]>("runtime_jobs")).length) return;
        await sleep(20);
      }
      throw Error("La cola no se vació");
    },
    async process<T = { versionId: string }>(id: string, options?: Record<string, unknown>): Promise<T> {
      if (options) return command<T>("runtime_run", { operation: "processRecording", args: { recordingId: id, options } });
      for (let attempt = 0; attempt < 1500; attempt++) {
        const page = await command<{ jobs: { recordingId: string; state: string; result: unknown; error: string | null }[] }>("runtime_history", { limit: 50 });
        const job = page.jobs.find((entry) => entry.recordingId === id && ["succeeded", "failed", "cancelled"].includes(entry.state));
        if (job) {
          if (job.state !== "succeeded") throw Error(job.error ?? "El trabajo falló");
          return job.result as T;
        }
        await sleep(20);
      }
      throw Error("El trabajo automático no terminó");
    },
    detail: (id: string) => command<Recording>("recording_detail", { id }),
    library: () => command<Snapshot>("library"),
    async recipe(recipe: Recipe) {
      await command("config_save", { collection: "recipes", item: recipe });
      await command("settings_save", { settings: { defaultRecipeId: recipe.id } });
    },
    async importAudio(name = "nota.wav", content = "audio sintetico") {
      mkdirSync(join(data, "inbox"), { recursive: true });
      const inbox = join(data, "inbox", name);
      writeFileSync(inbox, content);
      const [record] = await command<Recording[]>("import_inbox", { files: [{ inbox, source: `/origen/${name}` }] }, "shell");
      return record!.id;
    },
    async note(recipe: Recipe = FORM_RECIPE) {
      await host.recipe(recipe);
      return host.importAudio();
    },
    async close() {
      const stopping = [...workers.values(), child].map(async (process) => {
        if (process.exitCode !== null || process.signalCode !== null) return;
        const closed = once(process, "close");
        process.kill("SIGKILL");
        await closed;
      });
      workers.clear();
      await Promise.all(stopping);
      frames.close();
    },
  };
  return host;
}
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const versions = async (host: ReturnType<typeof supervisor>, id: string) => (await host.detail(id)).versions;

test("un dist externo aporta formularios, acciones y publicación en Bun aislado sin sus fuentes", async () => {
  const project = join(directory, "external");
  await mkdir(project);
  await cp(new URL("../../../../examples/conectores/src", import.meta.url), join(project, "src"), { recursive: true });
  const service = await localHttp((request) => request.url?.includes("by-key")
    ? { status: 404, body: "{}" }
    : request.url?.endsWith("/collections") ? { status: 200, body: '[{"id":"notes","name":"Notas"}]' } : { status: 200, body: '{"id":"created-1"}' });
  for (const entry of (await readdir(join(project, "src"), { withFileTypes: true })).filter((entry) => entry.isFile())) {
    const source = join(project, "src", entry.name);
    await writeFile(source, (await readFile(source, "utf8")).replace("'https://api.example.test'", JSON.stringify(service.origin)));
  }
  await writeFile(join(project, "package.json"), '{"type":"module"}');
  const vendor = fileURLToPath(new URL("../../node_modules", import.meta.url));
  const built = spawnSync(executable, ["--project-build", project, vendor], { encoding: "utf8" });
  assert.equal(built.status, 0, built.stderr);
  const program = await readFile(join(project, "dist/conectores.js"), "utf8");
  await rm(join(project, "src"), { recursive: true });
  const host = supervisor();
  try {
    await host.ready;
    const grant = { capability: "http" as const, origin: service.origin, allowedHeaders: ["content-type", "accept"], credential: { label: "Clave del servicio", header: "X-API-Key" } };
    await host.command("project_install", { recipes: [], providers: [{ id: "synthetic-notes", name: "Notas de ejemplo", ...grant, defaultConfiguration: {}, program }], destinations: [], ontologies: [] });
    await host.command("connector_save", {
      account: { id: "external-account", name: "Ejemplo", provider: "synthetic-notes", enabled: true, grant },
      destination: { id: "external-account", account: "external-account", name: "Ejemplo", provider: "synthetic-notes", enabled: true, configuration: { workspace: "demo", collection: "notes" } },
    });
    await host.command("credential_save", { id: "external-account", value: "token-sintético\n" });
    await host.recipe(FORM_RECIPE);
    const id = await host.importAudio();
    await host.process(id);
    await host.command("version_save", { recordingId: id, backend: "local-stt", transcript: { text: "Contenido sintético", segments: [] } });
    const request = { providerId: "synthetic-notes", accountId: "external-account", configuration: { workspace: "demo", collection: "notes" } };
    const view = await host.run<{ view: { sections: unknown[] } }>("connectorEditor", { operation: "describe", request });
    assert.equal(view.view.sections.length, 1);
    assert.equal(service.seen.length, 0);
    const action = await host.run<{ state: { collections: unknown[] } }>("connectorEditor", { operation: "action", request: { ...request, action: "refresh-collections" } });
    assert.deepEqual(action.state.collections, [{ id: "notes", name: "Notas" }]);
    await host.run("publishRecording", { recordingId: id, destinationId: "external-account" });
    const publication = (await host.detail(id)).publications.at(-1) as Record<string, unknown> | undefined;
    assert.equal((publication?.receipt as { locator: string }).locator, "created-1");
    assert.equal(publication?.managed, true);
    assert.equal(publication?.program, program);
    assert.equal(service.seen.filter((request) => request.method === "POST").length, 1);
    assert.ok(service.seen.every((request) => request.headers["x-api-key"] === "token-sintético"));
  } finally { await host.close(); service.close(); }
}, 30000);
test("el SDK oficial de Notion consulta y escribe desde una receta en Bun aislado", async () => {
  const service = await localHttp(() => ({ status: 200, body: '{"object":"list","results":[],"has_more":false,"next_cursor":null}' }));
  const bundled = await build({
    stdin: { resolveDir: fileURLToPath(new URL("../..", import.meta.url)), contents: `import {Client} from '@notionhq/client';
      export async function flujo(audio, escriba) {
        const client = new Client({fetch:escriba.cuenta('Trabajo').fetch, maxRetries:0, baseUrl:${JSON.stringify(service.origin)}});
        await client.users.list({page_size:1});
        await client.pages.create({parent:{page_id:'parent'},properties:{title:{title:[]}}});
        const note = await escriba.transcribir(audio); await note.guardar();
      }` },
    bundle: true, write: false, platform: "browser", format: "iife", globalName: "__recipe",
  });
  const grant = { capability: "http" as const, origin: service.origin, allowedHeaders: ["content-type", "accept", "notion-version"], credential: { label: "Token", header: "Authorization", prefix: "Bearer " } };
  const host = supervisor();
  try {
    await host.ready;
    await host.command("project_install", { recipes: [], providers: [{ id: "notion-local", name: "Notion local", ...grant, defaultConfiguration: {}, program: "var __connector={}" }], destinations: [], ontologies: [] });
    await host.command("connector_save", {
      account: { id: "notion-sdk", name: "Trabajo", provider: "notion-local", enabled: true, grant },
      destination: { id: "notion-sdk", account: "notion-sdk", name: "Trabajo", provider: "notion-local", enabled: true, configuration: {} },
    });
    await host.command("credential_save", { id: "notion-sdk", value: "token-notion-sintético" });
    const id = await host.note({ id: "default", name: "SDK", kind: "code", values: {}, bundle: bundled.outputFiles[0].text });
    await host.process(id);
    assert.deepEqual(service.seen.map((request) => request.method), ["GET", "POST"]);
    assert.ok(service.seen.every((request) => request.headers.authorization === "Bearer token-notion-sintético"));
    const detail = await host.detail(id);
    assert.equal(detail.accountEffectPending, true);
    assert.equal(detail.status, "done");
  } finally { await host.close(); service.close(); }
});
test("notificaciones consultan solo el contexto de configuración y devuelven los problemas", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const result = await host.run("notificationProblems", {
      status: { protocolVersion: 1, whisper: { available: false }, llm: { available: false, reason: "modelo aún no disponible" } },
    });
    assert.deepEqual(result, macos ? [
      { role: "stt", name: "Whisper · en este Mac", reason: "el modelo de Whisper no está descargado; descárgalo aquí abajo" },
      { role: "llm", name: "Apple Intelligence", reason: "modelo aún no disponible" },
    ] : [
      { role: "stt", name: "Whisper · en este equipo", reason: "el modelo de Whisper no está descargado; descárgalo aquí abajo" },
    ]);
    assert.deepEqual(host.methods.filter((method) => method !== "shell.native"), []);
    assert.deepEqual(host.nativeMethods, ["status"]);
  } finally {
    await host.close();
  }
});

test("el controlador abre la biblioteca, rechaza orígenes ajenos y devuelve la versión creada", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note();
    await assert.rejects(host.command("import_inbox", { files: [] }), /Origen no permitido para import_inbox/);
    await assert.rejects(host.command("snapshot", {}, "shell"), /Origen no permitido para snapshot/);
    const result = await host.process(id);
    const detail = await host.detail(id);
    assert.equal(detail.currentVersionId, result.versionId);
    assert.equal(detail.versions[0]?.transcript.text, "Texto preservado");
    assert.ok(host.events.some((event) => event.event === "jobs"));
    assert.ok(host.events.some((event) => event.event === "status"));
  } finally {
    await host.close();
  }
});
test("sidecar compilado preserva transcripción entre reinicios y las capacidades llevan el id del trabajo", async () => {
  let host = supervisor();
  let id = "";
  try {
    await host.ready;
    id = await host.note();
    await host.process(id);
    assert.equal((await versions(host, id)).length, 1);
    assert.ok(host.nativeMethods.includes("transcribe"));
    const jobTasks = host.calls.filter((call) => call.native === "transcribe").map((call) => call.taskId);
    assert.ok(jobTasks.length > 0 && jobTasks.every((task) => typeof task === "string" && task === jobTasks[0]), JSON.stringify(jobTasks));
  } finally {
    await host.close();
  }
  host = supervisor({ data: host.data });
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: id, options: { force: false } });
    assert.equal((await versions(host, id)).length, 1);
    assert.ok(!host.nativeMethods.includes("transcribe"));
  } finally {
    await host.close();
  }
});

test("el sidecar aplica los valores puntuales sin cambiar la receta guardada", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({ ...FORM_RECIPE, values: { idioma: "en", resumir: false } });
    await host.process(id);
    await host.process(id, { recipeId: "default", force: true, values: { idioma: "es", resumir: false } });
    assert.deepEqual((await versions(host, id)).map((version) => version.inputs?.language), ["en", "es"]);
    assert.deepEqual((await host.library()).recipes[0]?.values, { idioma: "en", resumir: false });
  } finally {
    await host.close();
  }
});

test("cancelación mata receta CPU y sidecar sigue disponible", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({ id: "default", name: "Bucle", kind: "code", values: {}, bundle: "var __recipe={flujo(){while(true){}}}" });
    const task = host.process(id);
    setTimeout(() => void host.cancel(id), 200);
    await assert.rejects(task, /cancelado/);
    await host.recipe(FORM_RECIPE);
    await host.run("getRecipeSchema", { recipeId: "default" });
  } finally {
    await host.close();
  }
});
test("el ejecutable usa Bun y conserva el recorrido de transcribir y guardar", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({
      id: "default", name: "Bun", kind: "code", values: {},
      bundle: `var __recipe={async flujo(audio,api){const p=await import('node:process');if(!p.versions.bun)throw Error('El ejecutable no usa Bun');await(await api.transcribir(audio)).guardar()}}`,
    });
    await host.process(id);
    const detail = await host.detail(id);
    assert.equal(detail.versions.length, 1);
    assert.equal(detail.status, "done");
  } finally {
    await host.close();
  }
});

test("las recetas pueden comparar texto con Intl dentro del sandbox", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({
      id: "default", name: "Orden", kind: "code", values: {},
      bundle: `var __recipe={async flujo(audio,api){
        const palabras=['zeta','ábaco'].sort((a,b)=>a.localeCompare(b,'es'));
        if(palabras[0]!=='ábaco')throw Error('Orden incorrecto');
        await(await api.transcribir(audio)).guardar();
      }}`,
    });
    await host.process(id);
    assert.equal((await versions(host, id)).length, 1);
  } finally {
    await host.close();
  }
});

test("una receta usa el SDK SurrealDB dentro del worker Bun aislado", async () => {
  const built = await build({
    stdin: {
      contents: `import { RecordId } from 'surrealdb';
        export const ontologias = [{ id: 'personas', minVersion: 2, maxVersion: 3 }];
        export async function flujo(audio, api) {
          const db = await api.grafo('personas');
          const id = new RecordId('persona', 'ada');
          const [people] = await db.query('SELECT * FROM persona WHERE id = $id', { id });
          if (!(people[0].id instanceof RecordId)) throw Error('RecordId perdido');
          await (await api.transcribir(audio)).guardar();
        }`,
      resolveDir: fileURLToPath(new URL("../../", import.meta.url)),
    },
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    globalName: "__recipe",
    nodePaths: [fileURLToPath(new URL("../../node_modules", import.meta.url))],
  });
  const host = supervisor({
    capability: async (method, params) => {
      if (method === "knowledge_open") return { version: 3 };
      if (method === "knowledge_query") {
        assert.equal(params.ontologyId, "personas");
        assert.equal(params.expectedVersion, 3);
        const bindings = CborCodec.DEFAULT.decode<Record<string, unknown>>(
          Buffer.from(String(params.bindings), "base64"),
        );
        assert.ok(bindings.id instanceof RecordId);
        return Buffer.from(CborCodec.DEFAULT.encode([[{ id: bindings.id }]])).toString("base64");
      }
      throw Error(`Capacidad inesperada: ${method}`);
    },
  });
  try {
    await host.ready;
    const id = await host.note({
      id: "default", name: "Grafo", kind: "code", values: {},
      ontologies: [{ id: "personas", minVersion: 2, maxVersion: 3 }],
      bundle: built.outputFiles[0].text,
    });
    await host.process(id);
    assert.ok(host.methods.includes("knowledge_query"));
    const detail = await host.detail(id);
    assert.equal(detail.versions.length, 1);
    assert.equal(detail.accountEffectPending, true);
  } finally {
    await host.close();
  }
});

isolation("el sandbox impide leer y escribir archivos y mantiene separado el canal de capacidades", async () => {
  const canary = join(directory, "canary.txt");
  await writeFile(canary, "private-fixture");
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({
      id: "default",
      name: "Sandbox",
      kind: "code",
      values: {},
      bundle: `var __recipe={async flujo(audio,api){
        const fs=await import('node:fs/promises');
        for(const attempt of [()=>fs.readFile(${JSON.stringify(canary)}),()=>Bun.file(${JSON.stringify(canary)}).text(),()=>fs.writeFile(${JSON.stringify(canary)},'overwrite')]){
          let denied=false;
          try{await attempt()}catch(error){denied=['EPERM','EACCES'].includes(error.code)}
          if(!denied)throw Error('sandbox de archivos abierto');
        }
        await(await api.transcribir(audio)).guardar();
      }}`,
    });
    await host.process(id);
    assert.equal((await versions(host, id)).length, 1);
    await host.recipe({ id: "default", name: "Forjada", kind: "code", values: {}, bundle: `var __recipe={async flujo(){const p=await import('node:process');p.stdout.write(JSON.stringify({type:'call',id:'forged',method:'credential_save',params:{id:'a',value:'fake'}})+'\\n');await new Promise(()=>{})}}` });
    await assert.rejects(host.process(id, { force: true }), /Solicitud del Worker no válida/);
    assert.ok(!host.methods.includes("credential_save"));
    await host.run("getRecipeSchema", { recipeId: "default" });
  } finally {
    await host.close();
  }
});

isolation("el sandbox rechaza conexiones a un servidor local que sí está escuchando", async () => {
  let connections = 0;
  const server = createServer((socket) => { connections++; socket.end(); });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  await new Promise<void>((resolve, reject) => {
    const socket = connect(address.port, "127.0.0.1", () => { socket.destroy(); resolve(); });
    socket.on("error", reject);
  });
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({
      id: "default", name: "Red", kind: "code", values: {},
      bundle: `var __recipe={async flujo(audio,api){
        const net=await import('node:net');let denied=false;
        try{await new Promise((resolve,reject)=>{const socket=net.connect(${address.port},'127.0.0.1',()=>{socket.destroy();resolve()});socket.on('error',reject)})}catch(error){denied=['EPERM','EACCES','ECONNREFUSED'].includes(error.code)}
        if(!denied)throw Error('sandbox de red abierto');
        await(await api.transcribir(audio)).guardar();
      }}`,
    });
    await host.process(id);
    assert.equal(connections, 1);
  } finally {
    await host.close();
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("cancelar inferencia sin respuesta libera cola para la siguiente grabación", async () => {
  const host = supervisor({ hangFirstTranscribe: true });
  try {
    await host.ready;
    const id = await host.note();
    const first = host.process(id);
    while (!host.nativeMethods.includes("transcribe"))
      await new Promise((resolve) => setTimeout(resolve, 10));
    await host.cancel(id);
    await assert.rejects(first, /cancelado/);
    assert.ok(host.methods.includes("shell.native_cancel"));
    await host.process(id, { force: true });
    assert.equal((await versions(host, id)).length, 1);
  } finally {
    await host.close();
  }
});
isolation("el sandbox impide crear procesos y relanzar el propio ejecutable", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({
      id: "default", name: "Procesos", kind: "code", values: {},
      bundle: `var __recipe={async flujo(audio,api){
        const cp=await import('node:child_process');
        const p=await import('node:process');
        const deniedCodes=${JSON.stringify(windows ? ['EPERM','EACCES','EUNKNOWN'] : ['EPERM','EACCES'])};
        for(const path of ${windows ? '[p.execPath]' : "['/usr/bin/true',p.execPath]"}){
          const result=cp.spawnSync(path,['--worker'],{timeout:100});
          if(!deniedCodes.includes(result.error?.code))throw Error('subproceso permitido: '+result.error?.code);
          let denied=false;
          try{Bun.spawnSync([path,'--worker'],{timeout:100})}catch(error){denied=deniedCodes.includes(error.code)}
          if(!denied)throw Error('subproceso Bun permitido');
        }
        await(await api.transcribir(audio)).guardar();
      }}`,
    });
    await host.process(id);
    assert.equal((await versions(host, id)).length, 1);
  } finally {
    await host.close();
  }
});

test("las dependencias empaquetadas usan módulos nativos de Bun sin acceder al disco", async () => {
  const host = supervisor();
  try {
    await host.ready;
    const id = await host.note({
      id: "default", name: "Módulos nativos", kind: "code", values: {},
      bundle: `var __recipe=(()=>{const module={exports:{}};const exports=module.exports;
        const path=require('node:path');const crypto=require('node:crypto');
        exports.flujo=async(audio,api)=>{
          if(path.basename('/a/nota.m4a')!=='nota.m4a'||crypto.createHash('sha256').update('synthetic').digest('hex').length!==64)throw Error('API nativa incorrecta');
          let denied=false;try{require('unbundled-package')}catch{denied=true}
          if(!denied)throw Error('Se cargó una dependencia externa');
          await(await api.transcribir(audio)).guardar();
        };return module.exports;})()`,
    });
    await host.process(id);
    assert.equal((await versions(host, id)).length, 1);
  } finally {
    await host.close();
  }
});
