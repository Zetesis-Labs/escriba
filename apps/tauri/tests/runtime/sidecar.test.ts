import { beforeAll, afterAll, test } from "vitest";
import assert from "node:assert/strict";
import {
  spawn,
  spawnSync,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
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
function supervisor(state: Snapshot, hangFirstTranscribe = false) {
  let hung = false;
  const cancelled = new Set<string>();
  const child = spawn(executable, [], { env: {} });
  const workers = new Map<string, ChildProcessWithoutNullStreams>();
  const pending = new Map<
    string,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  const methods: string[] = [];
  const taskIds: unknown[] = [];
  const events: unknown[] = [];
  let readyResolve!: () => void;
  const ready = new Promise<void>((resolve) => {
    readyResolve = resolve;
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
      const worker = spawn(executable, ["--worker"], { env: {} });
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
      if (value.method === "runtime_context") result = runtimeContext(state, params.recordingId);
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
        send({
          type: "reject",
          id,
          message: `Capacidad no esperada ${value.method}`,
        });
        return;
      }
      send({ type: "resolve", id, value: result });
    }
  });
  child.on("exit", (code) => {
    for (const waiter of pending.values())
      waiter.reject(Error(`sidecar ${code}: ${stderr}`));
  });
  return {
    ready,
    methods,
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
test("proceso receta no puede leer ficheros/red ni falsificar capacidades del proceso principal", async () => {
  const canary = join(directory, "canary.txt");
  await writeFile(canary, "private-fixture");
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default",
    name: "Sandbox",
    kind: "code",
    values: {},
    bundle: `var __recipe={async flujo(audio,api){let blocked=0;try{await Deno.readTextFile(${JSON.stringify(canary)})}catch{blocked++}try{await Deno.connect({hostname:'127.0.0.1',port:9})}catch{blocked++}if(blocked!==2)throw Error('sandbox abierto');await(await api.transcribir(audio)).guardar()}}`,
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
test("heap de receta queda limitado y una fuga no termina el controlador", async () => {
  const state = structuredClone(snapshot);
  state.recipes[0] = {
    id: "default",
    name: "Fuga",
    kind: "code",
    values: {},
    bundle:
      'var __recipe={flujo(){globalThis.leak=[];while(true)globalThis.leak.push(new Array(100000).fill("memory"))}}',
  };
  const host = supervisor(state);
  try {
    await host.ready;
    await assert.rejects(
      host.run("processRecording", { recordingId: "r" }).result,
      /worker terminó/,
    );
    state.recipes[0] = structuredClone(snapshot.recipes[0]);
    await host.run("getRecipeSchema", { recipeId: "default" }).result;
  } finally {
    host.close();
  }
}, 15000);
