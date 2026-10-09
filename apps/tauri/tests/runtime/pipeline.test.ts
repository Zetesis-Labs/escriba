import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller.js";
import type { Snapshot, Version } from "../../src/types.js";
import { snapshot, runtimeContext } from "./fixture";

test("persiste transcripción antes del resumen fallido y conserva el aviso", async () => {
  const state = structuredClone(snapshot);
  const calls: string[] = [];
  const controller = createRuntime(
    {
      call: async (method, params = {}) => {
        calls.push(method);
        if (method === "runtime_context") return runtimeContext(state, params.recordingId);
        if (method === "transcribe") return { text: "Hola", segments: [] };
        if (method === "version_save") {
          const v = {
            ...params,
            id: "v1",
            createdAt: "now",
          } as unknown as Version;
          state.recordings[0].versions.push(v);
          return v;
        }
        if (method === "summarize") throw Error("LLM no disponible");
        return undefined;
      },
    },
    {
      run: async (task, context) => {
        await context.call("transcribe", { stt: "local-stt" });
        try {
          await context.call("summarize", { llm: "local-llm" });
        } catch {
          await context.call("log", {
            message: "LLM no disponible",
            level: "warn",
          });
        }
        await context.call("save", {});
        return null;
      },
    },
  );
  await controller.processRecording("r");
  assert.ok(calls.indexOf("version_save") < calls.indexOf("summarize"));
  assert.ok(calls.includes("log"));
  assert.equal(state.recordings[0].versions.length, 1);
  assert.equal(controller.getJobs().length, 0);
});
