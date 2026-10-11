import { beforeAll, afterAll, test } from "vitest";
import assert from "node:assert/strict";
import {
  spawn,
  spawnSync,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { connect, createServer } from "node:net";
import { build } from "esbuild";
import { CborCodec, RecordId } from "surrealdb";
import { snapshot, runtimeContext } from "./fixture";
import type { Snapshot, Version } from "../../src/types";
let directory = "";
let executable = "";
beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "escriba-runtime-"));
  executable = join(directory, "runtime");
  const build = fileURLToPath(
    new URL("../../runtime-host/build.mjs", import.meta.url),
  );
  const result = spawnSync(process.execPath, [build, executable], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
}, 30000);
afterAll(async () => {
  await rm(directory, { recursive: true, force: true });
});
function launch(worker = false) {
  const path = realpathSync(executable);
  const profile = readFileSync(new URL("../../runtime-host/sandbox.sb", import.meta.url), "utf8");
  return spawn("/usr/bin/sandbox-exec", [
    "-p", profile, "-D", `EXECUTABLE=${path}`, path, ...(worker ? ["--worker"] : []),
  ], { env: {}, cwd: "/" });
}
function supervisor(state: Snapshot, hangFirstTranscribe = false, onCall?: (method: string, params: Record<string, unknown>) => void, capability?: (method: string, params: Record<string, unknown>) => Promise<unknown>) {
  let hung = false;
  const cancelled = new Set<string>();
  const child = launch();
  const workers = new Map<string, ChildProcessWithoutNullStreams>();
  const pending = new Map<
    string,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  const methods: string[] = [];
  const contextRequests: Record<string, unknown>[] = [];
  const taskIds: unknown[] = [];
  const events: unknown[] = [];
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
      const worker = launch(true);
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
      events.push(value);
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
      if (cancelled.has(String(value.taskId))) return;
      methods.push(value.method);
      if (value.method === "transcribe" && hangFirstTranscribe && !hung) {
        hung = true;
        return;
      }
      taskIds.push(value.taskId);
      let result: unknown = null;
      const params = value.params;
      const record =
        state.recordings.find(
          (r) => r.id === params.recordingId || r.id === params.id,
        ) || state.recordings[0];
      if (value.method === "runtime_context") {
        contextRequests.push(params);
        result = runtimeContext(state, params.recordingId);
      }
      else if (value.method === "transcribe")
        result = { text: "Texto preservado", segments: [] };
      else if (value.method === "recording_update")
        Object.assign(record, params);
      else if (value.method === "version_save") {
        const version = {
          ...params,
          id: `v${record.versions.length + 1}`,
          createdAt: "now",
        } as Version;
        record.versions.push(version);
        record.currentVersionId = version.id;
        result = version;
      } else if (value.method === "version_update") {
        Object.assign(
          record.versions.find((v) => v.id === params.versionId)!,
          params,
        );
      } else if (value.method === "version_select")
        record.currentVersionId = params.versionId;
      else if (
        ![
          "log",
          "native_cancel",
          "trace_save",
          "memory_recall",
          "memory_keep",
        ].includes(value.method)
      ) {
        if (capability) {
          try { result = await capability(value.method, params); }
          catch (error) {
            send({ type: "reject", id, message: String(error) });
            return;
          }
        } else {
        send({
          type: "reject",
          id,
          message: `Capacidad no esperada ${value.method}`,
        });
        return;
        }
      }
      onCall?.(value.method, params);
      send({ type: "resolve", id, value: result });
    }
  });
  child.on("exit", (code) => {
    readyReject(Error(`sidecar ${code}: ${stderr}`));
    for (const waiter of pending.values())
      waiter.reject(Error(`sidecar ${code}: ${stderr}`));
  });
  return {
    ready,
    methods,
    contextRequests,
    taskIds,
    events,
    run(operation: string, args: Record<string, unknown>) {
      const id = `task-${++counter}`;
      const result = new Promise<unknown>((resolve, reject) =>
        pending.set(id, { resolve, reject }),
      );
      send({ type: "run", id, operation, args });
      return { id, result };
    },
    cancel(id: string) {
      cancelled.add(id);
      send({ type: "cancel", id });
    },
    close() {
      for (const worker of workers.values()) worker.kill("SIGKILL");
      workers.clear();
      child.kill("SIGKILL");
      frames.close();
    },
  };
}
test("un dist externo aporta formularios, acciones y publicación en Bun aislado sin sus fuentes", async () => {
  const project = join(directory, "external");
  await mkdir(project);
  await cp(new URL("../../../../examples/conectores/src", import.meta.url), join(project, "src"), { recursive: true });
  await writeFile(join(project, "package.json"), '{"type":"module"}');
  const vendor = fileURLToPath(new URL("../../node_modules", import.meta.url));
  const built = spawnSync(executable, ["--project-build", project, vendor], { encoding: "utf8" });
  assert.equal(built.status, 0, built.stderr);
  const program = await readFile(join(project, "dist/conectores.js"), "utf8");
  await rm(join(project, "src"), { recursive: true });
  const state = structuredClone(snapshot);
  const grant = { capability: "http" as const, origin: "https://api.example.test", allowedHeaders: ["content-type", "accept"], credential: { label: "Clave del servicio", header: "X-API-Key" } };
  state.providers = [{ id: "synthetic-notes", name: "Notas de ejemplo", ...grant, defaultConfiguration: {}, program }];
  state.accounts = [{ id: "external-account", name: "Ejemplo", provider: "synthetic-notes", enabled: true, grant }];
  state.destinations = [{ id: "external-account", account: "external-account", name: "Ejemplo", provider: "synthetic-notes", enabled: true, managed: true, configuration: { workspace: "demo", collection: "notes" }, program }];
  state.recordings[0].versions = [{ id: "v", createdAt: "now", backend: "local-stt", transcript: { text: "Contenido sintético", segments: [] } }];
  const receipts: Record<string, unknown>[] = [];
  const http: Record<string, unknown>[] = [];
  const host = supervisor(state, false, undefined, async (method, params) => {
    if (method === "publication_save") { receipts.push(params); return null; }
    if (method !== "connector_http") throw Error(`Capacidad inesperada: ${method}`);
    http.push(params);
    assert.equal(params.accountId, "external-account");
    assert.deepEqual(params.expectedGrant, grant);
    assert.ok(!JSON.stringify(params).includes("token-sintético"));
    const url = String(params.url);
    return { status: url.includes("by-key") ? 404 : 200, headers: { "content-type": "application/json" }, body: url.endsWith("/collections") ? '[{"id":"notes","name":"Notas"}]' : '{"id":"created-1"}' };
  });
  try {
    await host.ready;
    const request = { providerId: "synthetic-notes", accountId: "external-account", configuration: { workspace: "demo", collection: "notes" } };
    const view = await host.run("connectorEditor", { operation: "describe", request }).result as { view: { sections: unknown[] } };
    assert.equal(view.view.sections.length, 1);
    assert.equal(http.length, 0);
    const action = await host.run("connectorEditor", { operation: "action", request: { ...request, action: "refresh-collections" } }).result as { state: { collections: unknown[] } };
    assert.deepEqual(action.state.collections, [{ id: "notes", name: "Notas" }]);
    await host.run("publishRecording", { recordingId: "r", destinationId: "external-account" }).result;
    assert.equal((receipts.at(-1)?.receipt as { locator: string }).locator, "created-1");
    assert.equal(receipts.at(-1)?.managed, true);
    assert.equal(receipts.at(-1)?.program, program);
    assert.equal(http.filter((request) => request.method === "POST").length, 1);
  } finally { host.close(); }
}, 30000);
test("el SDK oficial de Notion consulta y escribe desde una receta en Bun aislado", async () => {
  const bundled = await build({
    stdin: { resolveDir: fileURLToPath(new URL("../..", import.meta.url)), contents: `import {Client} from '@notionhq/client';
      export async function flujo(audio, escriba) {
        const client = new Client({fetch:escriba.cuenta('Trabajo').fetch, maxRetries:0});
        await client.users.list({page_size:1});
        await client.pages.create({parent:{page_id:'parent'},properties:{title:{title:[]}}});
        const note = await escriba.transcribir(audio); await note.guardar();
      }` },
    bundle: true, write: false, platform: "browser", format: "iife", globalName: "__recipe",
  });
  const state = structuredClone(snapshot);
  state.recipes[0] = { id: "default", name: "SDK", kind: "code", values: {}, bundle: bundled.outputFiles[0].text };
  state.accounts = [{ id: "notion-sdk", name: "Trabajo", provider: "notion", enabled: true, origin: "https://api.notion.com" }];
  const sent: Record<string, unknown>[] = [];
  const host = supervisor(state, false, undefined, async (method, params) => {
    if (method === "account_effect_begin") { state.recordings[0].accountEffectPending = true; return null; }
    if (method !== "connector_http") throw Error(`Capacidad inesperada: ${method}`);
    sent.push(params);
    if (params.method === "POST") assert.equal(state.recordings[0].accountEffectPending, true);
    return { status: 200, headers: { "content-type": "application/json" }, body: '{"object":"list","results":[],"has_more":false,"next_cursor":null}' };
  });
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.deepEqual(sent.map((request) => request.method), ["GET", "POST"]);
    assert.ok(sent.every((request) => request.accountId === "notion-sdk"));
    assert.equal(state.recordings[0].accountEffectPending, true);
    assert.equal(state.recordings[0].status, "done");
  } finally { host.close(); }
});
test("notificaciones consultan solo el contexto de configuración y devuelven los problemas", async () => {
  const state = structuredClone(snapshot);
  const host = supervisor(state);
  try {
    await host.ready;
    const result = await host.run("notificationProblems", {
      status: { protocolVersion: 1, whisper: { available: false }, llm: { available: false, reason: "modelo aún no disponible" } },
    }).result;
    assert.deepEqual(result, [
      { role: "stt", name: "Whisper", reason: "el modelo de Whisper no está descargado; descárgalo aquí abajo" },
      { role: "llm", name: "Apple", reason: "modelo aún no disponible" },
    ]);
    assert.deepEqual(host.methods, ["runtime_context"]);
    assert.deepEqual(host.contextRequests, [{}]);
  } finally {
    host.close();
  }
});

test("procesar devuelve la versión creada aunque cambie la selección durante el cierre", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0].values = { resumir: false };
  state.recordings[0].versions.push({
    id: "v0", createdAt: "antes", backend: "Whisper", recipeId: "default",
    transcript: { text: "Anterior", segments: [] }, inputs: {},
  });
  state.recordings[0].currentVersionId = "v0";
  const host = supervisor(state, false, (method, params) => {
    if (method === "recording_update" && params.status === "done") state.recordings[0].currentVersionId = "v0";
  });
  try {
    await host.ready;
    const result = await host.run("processRecording", { recordingId: "r" }).result;
    assert.deepEqual(result, { versionId: "v2" });
    assert.equal(state.recordings[0].currentVersionId, "v0");
  } finally {
    host.close();
  }
});
test("sidecar compilado preserva transcripción entre reinicios y emite jobs/capacidades con taskId", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0].values = { resumir: false };
  let host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", {
      recordingId: "r",
      options: { force: false },
    }).result;
    assert.equal(state.recordings[0].versions.length, 1);
    assert.ok(host.methods.includes("transcribe"));
    assert.ok(host.taskIds.every((id) => id === "task-1"));
    assert.ok(host.events.length > 0);
  } finally {
    host.close();
  }
  host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", {
      recordingId: "r",
      options: { force: false },
    }).result;
    assert.equal(state.recordings[0].versions.length, 1);
    assert.ok(!host.methods.includes("transcribe"));
  } finally {
    host.close();
  }
});

test("el sidecar aplica los valores puntuales sin cambiar la receta guardada", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0].values = { idioma: "en", resumir: false };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", {
      recordingId: "r",
      options: { recipeId: "default", force: true, values: { idioma: "es", resumir: false } },
    }).result;
    await host.run("processRecording", { recordingId: "r", options: { force: true } }).result;
    assert.deepEqual(state.recordings[0].versions.map((version) => version.inputs?.language), ["es", "en"]);
    assert.deepEqual(state.recipes[0].values, { idioma: "en", resumir: false });
  } finally {
    host.close();
  }
});

test("cancelación mata receta CPU y sidecar sigue disponible", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default",
    name: "Bucle",
    kind: "code",
    values: {},
    bundle: "var __recipe={flujo(){while(true){}}}",
  };
  const host = supervisor(state);
  try {
    await host.ready;
    const task = host.run("processRecording", { recordingId: "r" });
    setTimeout(() => host.cancel(task.id), 200);
    await assert.rejects(task.result, /cancelado/);
    state.recipes[0] = structuredClone(snapshot.recipes[0]);
    await host.run("getRecipeSchema", { recipeId: "default" }).result;
  } finally {
    host.close();
  }
});
test("el ejecutable usa Bun y conserva el recorrido de transcribir y guardar", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default", name: "Bun", kind: "code", values: {},
    bundle: `var __recipe={async flujo(audio,api){const p=await import('node:process');if(!p.versions.bun)throw Error('El ejecutable no usa Bun');await(await api.transcribir(audio)).guardar()}}`,
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(state.recordings[0].versions.length, 1);
    assert.equal(state.recordings[0].status, "done");
  } finally {
    host.close();
  }
});

test("las recetas pueden comparar texto con Intl dentro del sandbox", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default", name: "Orden", kind: "code", values: {},
    bundle: `var __recipe={async flujo(audio,api){
      const palabras=['zeta','ábaco'].sort((a,b)=>a.localeCompare(b,'es'));
      if(palabras[0]!=='ábaco')throw Error('Orden incorrecto');
      await(await api.transcribir(audio)).guardar();
    }}`,
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(state.recordings[0].versions.length, 1);
  } finally {
    host.close();
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
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default", name: "Grafo", kind: "code", values: {},
    ontologies: [{ id: "personas", minVersion: 2, maxVersion: 3 }],
    bundle: built.outputFiles[0].text,
  };
  const methods: string[] = [];
  const host = supervisor(state, false, (method) => methods.push(method), async (method, params) => {
    if (method === "knowledge_open") return { version: 3 };
    if (method === "account_effect_begin") return null;
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
  });
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.ok(methods.includes("knowledge_query"));
    assert.equal(state.recordings[0].versions.length, 1);
  } finally {
    host.close();
  }
});

test("el sandbox impide leer y escribir archivos y mantiene separado el canal de capacidades", async () => {
  const canary = join(directory, "canary.txt");
  await writeFile(canary, "private-fixture");
  const state = structuredClone(snapshot);
  state.recipes[0] = {
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
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(state.recordings[0].versions.length, 1);
    state.recipes[0].bundle = `var __recipe={async flujo(){const p=await import('node:process');p.stdout.write(JSON.stringify({type:'call',id:'forged',method:'credential_save',params:{id:'a',value:'fake'}})+'\\n');await new Promise(()=>{})}}`;
    await assert.rejects(
      host.run("processRecording", { recordingId: "r" }).result,
      /Solicitud del Worker no válida/,
    );
    assert.ok(!host.methods.includes("credential_save"));
    await host.run("getRecipeSchema", { recipeId: "default" }).result;
  } finally {
    host.close();
  }
});

test("el sandbox rechaza conexiones a un servidor local que sí está escuchando", async () => {
  let connections = 0;
  const server = createServer((socket) => { connections++; socket.end(); });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  await new Promise<void>((resolve, reject) => {
    const socket = connect(address.port, "127.0.0.1", () => { socket.destroy(); resolve(); });
    socket.on("error", reject);
  });
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default", name: "Red", kind: "code", values: {},
    bundle: `var __recipe={async flujo(audio,api){
      const net=await import('node:net');let denied=false;
      try{await new Promise((resolve,reject)=>{const socket=net.connect(${address.port},'127.0.0.1',()=>{socket.destroy();resolve()});socket.on('error',reject)})}catch(error){denied=['EPERM','EACCES','ECONNREFUSED'].includes(error.code)}
      if(!denied)throw Error('sandbox de red abierto');
      await(await api.transcribir(audio)).guardar();
    }}`,
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(connections, 1);
  } finally {
    host.close();
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("cancelar inferencia sin respuesta libera cola para la siguiente grabación", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0].values = { resumir: false };
  const host = supervisor(state, true);
  try {
    await host.ready;
    const first = host.run("processRecording", { recordingId: "r" });
    while (!host.methods.includes("transcribe"))
      await new Promise((resolve) => setTimeout(resolve, 10));
    host.cancel(first.id);
    await assert.rejects(first.result, /cancelado/);
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(state.recordings[0].versions.length, 1);
  } finally {
    host.close();
  }
});
test("el sandbox impide crear procesos y relanzar el propio ejecutable", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default", name: "Procesos", kind: "code", values: {},
    bundle: `var __recipe={async flujo(audio,api){
      const cp=await import('node:child_process');
      const p=await import('node:process');
      for(const path of ['/usr/bin/true',p.execPath]){
        const result=cp.spawnSync(path,['--worker'],{timeout:100});
        if(!['EPERM','EACCES'].includes(result.error?.code))throw Error('subproceso permitido: '+result.error?.code);
        let denied=false;
        try{Bun.spawnSync([path,'--worker'],{timeout:100})}catch(error){denied=['EPERM','EACCES'].includes(error.code)}
        if(!denied)throw Error('subproceso Bun permitido');
      }
      await(await api.transcribir(audio)).guardar();
    }}`,
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(state.recordings[0].versions.length, 1);
  } finally {
    host.close();
  }
});

test("las dependencias empaquetadas usan módulos nativos de Bun sin acceder al disco", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default", name: "Módulos nativos", kind: "code", values: {},
    bundle: `var __recipe=(()=>{const module={exports:{}};const exports=module.exports;
      const path=require('node:path');const crypto=require('node:crypto');
      exports.flujo=async(audio,api)=>{
        if(path.basename('/a/nota.m4a')!=='nota.m4a'||crypto.createHash('sha256').update('synthetic').digest('hex').length!==64)throw Error('API nativa incorrecta');
        let denied=false;try{require('unbundled-package')}catch{denied=true}
        if(!denied)throw Error('Se cargó una dependencia externa');
        await(await api.transcribir(audio)).guardar();
      };return module.exports;})()`,
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await host.run("processRecording", { recordingId: "r" }).result;
    assert.equal(state.recordings[0].versions.length, 1);
  } finally {
    host.close();
  }
});
