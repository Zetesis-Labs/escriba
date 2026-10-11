import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller";
import type { WorkerTask } from "../../src/runtime/contracts";
import { snapshot, runtimeContext } from "./fixture";

test("el controlador no encadena notas distintas: el orden lo decide la cola de Rust", async () => {
  const state = structuredClone(snapshot);
  state.recordings.push({ ...structuredClone(state.recordings[0]), id: "s", title: "Otra" });
  const started: string[] = [];
  let release = () => {};
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const runtime = createRuntime(
    {
      call: async (method, params = {}) =>
        method === "runtime_context" ? runtimeContext(state, params.recordingId) : null,
    },
    {
      run: async (task: WorkerTask) => {
        const key = String((task.payload.audio as { clave: string }).clave);
        started.push(key);
        if (key === "r") await gate;
        return null;
      },
    },
  );
  const first = runtime.processRecording("r").catch(() => null);
  await new Promise<void>((resolve) => setImmediate(resolve));
  await runtime.processRecording("s").catch(() => null);
  assert.deepEqual(started, ["r", "s"]);
  release();
  await first;
});

test("la misma nota no se procesa dos veces a la vez", async () => {
  let release = () => {};
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const runtime = createRuntime(
    {
      call: async (method, params = {}) =>
        method === "runtime_context" ? runtimeContext(snapshot, params.recordingId) : null,
    },
    { run: async () => { await gate; return null; } },
  );
  const first = runtime.processRecording("r").catch(() => null);
  await assert.rejects(runtime.processRecording("r"), /ya se está procesando/);
  release();
  await first;
});
