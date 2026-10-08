import { AsyncLocalStorage } from "node:async_hooks";
import { createRuntime } from "../src/runtime/controller";
import {
  createWorkerRunner,
  type WorkerPort,
} from "../src/runtime/workerClient";
import { object, text, message } from "../src/runtime/contracts";
import type { ProcessOptions } from "../src/types";
declare const __WORKER_SOURCE__: string;
declare const __BUILTIN_PROGRAM__: string;
type ID = string | number;
const encoder = new TextEncoder();
let writing = Promise.resolve();
function send(value: unknown) {
  const data = encoder.encode(`${JSON.stringify(value)}\n`);
  writing = writing.then(async () => {
    let offset = 0;
    while (offset < data.length)
      offset += await Deno.stdout.write(data.subarray(offset));
  });
  return writing;
}
async function* frames() {
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const bytes of Deno.stdin.readable) {
    buffer += decoder.decode(bytes, { stream: true });
    if (buffer.length > 32 * 1024 * 1024) throw Error("Trama demasiado grande");
    let end: number;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (line.trim()) yield JSON.parse(line);
    }
  }
  if (buffer.trim()) throw Error("Trama incompleta al cerrar stdin");
}
function identifier(value: unknown): ID {
  if (typeof value === "string" && value.length && value.length < 256)
    return value;
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0)
    return value;
  throw Error("ID de protocolo inválido");
}
async function workerProcess() {
  Object.defineProperty(globalThis, "postMessage", {
    value: (value: unknown) => {
      void send(value);
    },
    writable: false,
  });
  new Function(__WORKER_SOURCE__)();
  for await (const value of frames())
    (
      globalThis as typeof globalThis & { onmessage?: WorkerPort["onmessage"] }
    ).onmessage?.({ data: value } as MessageEvent);
  await writing;
}
async function main() {
  const context = new AsyncLocalStorage<ID>();
  const pending = new Map<
    string,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      taskId?: ID;
    }
  >();
  const workers = new Map<string, WorkerPort>();
  const workerTasks = new Map<string, ID | undefined>();
  const running = new Map<
    ID,
    { recordingId?: string; abort: AbortController }
  >();
  let sequence = 0;
  const host = {
    call(method: string, params: Record<string, unknown> = {}) {
      const taskId = context.getStore();
      if (taskId !== undefined && running.get(taskId)?.abort.signal.aborted)
        return Promise.reject(
          new DOMException("Proceso cancelado", "AbortError"),
        );
      const id = `call-${++sequence}`;
      return new Promise<unknown>((resolve, reject) => {
        pending.set(id, { resolve, reject, taskId });
        void send({
          type: "call",
          id,
          method,
          params,
          taskId: context.getStore(),
        }).catch((error) => {
          pending.delete(id);
          reject(error);
        });
      });
    },
  };
  const runner = createWorkerRunner(() => {
    if (workers.size >= 8) throw Error("Demasiadas ejecuciones de recetas");
    const id = `worker-${++sequence}`;
    const port: WorkerPort = {
      onmessage: null,
      onerror: null,
      onmessageerror: null,
      postMessage(value) {
        void send({ type: "worker_send", id, value });
      },
      terminate() {
        if (workers.delete(id)) {
          workerTasks.delete(id);
          void send({ type: "worker_terminate", id });
        }
      },
    };
    workers.set(id, port);
    workerTasks.set(id, context.getStore());
    void send({ type: "worker_create", id, taskId: context.getStore() });
    return port;
  });
  const scopedRunner = {
    run(
      task: Parameters<typeof runner.run>[0],
      scope: Parameters<typeof runner.run>[1],
    ) {
      const id = context.getStore();
      const abort =
        id === undefined ? undefined : running.get(id)?.abort.signal;
      return runner.run(task, {
        ...scope,
        signal:
          scope.signal && abort
            ? AbortSignal.any([scope.signal, abort])
            : scope.signal || abort,
      });
    },
  };
  const runtime = createRuntime(host, scopedRunner, {
    builtinProgram: __BUILTIN_PROGRAM__,
  });
  runtime.subscribeJobs(() => {
    void send({ type: "event", event: "jobs", value: runtime.getJobs() });
  });
  async function execute(operation: string, args: Record<string, unknown>) {
    switch (operation) {
      case "processRecording":
        return runtime.processRecording(
          text(args.recordingId, "grabación"),
          args.options === undefined
            ? undefined
            : (object(args.options) as ProcessOptions),
        );
      case "summarizeRecording":
        return runtime.summarizeRecording(
          text(args.recordingId, "grabación"),
          typeof args.llm === "string" ? args.llm : undefined,
        );
      case "publishRecording":
        return runtime.publishRecording(
          text(args.recordingId, "grabación"),
          text(args.destinationId, "destino"),
        );
      case "unpublishRecording":
        return runtime.unpublishRecording(
          text(args.recordingId, "grabación"),
          text(args.destinationId, "destino"),
        );
      case "previewDestination":
        return runtime.previewDestination(
          text(args.destinationId, "destino"),
          typeof args.recordingId === "string" ? args.recordingId : undefined,
        );
      case "discoverDestination":
        return runtime.discoverDestination(text(args.destinationId, "destino"));
      case "validateDestination":
        return runtime.validateDestination(text(args.destinationId, "destino"));
      case "getRecipeSchema":
        return runtime.getRecipeSchema(text(args.recipeId, "receta"));
      case "rebuildProject":
        return runtime.rebuildProject();
      default:
        throw Error(`Operación no permitida: ${operation}`);
    }
  }
  await send({ type: "ready", protocolVersion: 1 });
  try {
    for await (const raw of frames()) {
      const frame = object(raw);
      const id = identifier(frame.id);
      if (frame.type === "resolve" || frame.type === "reject") {
        const waiter = pending.get(String(id));
        if (!waiter) continue;
        pending.delete(String(id));
        if (frame.type === "resolve") waiter.resolve(frame.value);
        else waiter.reject(Error(String(frame.message)));
        continue;
      }
      if (frame.type === "worker_message" || frame.type === "worker_error") {
        const port = workers.get(String(id));
        if (!port) continue;
        const deliver = () => {
          if (frame.type === "worker_message")
            port.onmessage?.({ data: frame.value } as MessageEvent);
          else port.onerror?.({ message: String(frame.message) } as ErrorEvent);
        };
        const owner = workerTasks.get(String(id));
        if (owner === undefined) deliver();
        else context.run(owner, deliver);
        continue;
      }
      if (frame.type === "cancel") {
        const task = running.get(id);
        if (task)
          context.run(id, () => {
            task.abort.abort();
            for (const [callId, waiter] of pending) {
              if (waiter.taskId === id) {
                pending.delete(callId);
                waiter.reject(
                  new DOMException("Proceso cancelado", "AbortError"),
                );
              }
            }
            if (task.recordingId) runtime.cancelProcessing(task.recordingId);
          });
        continue;
      }
      if (frame.type !== "run") throw Error("Trama de protocolo no permitida");
      if (running.has(id)) {
        await send({ type: "error", id, message: "ID de ejecución repetido" });
        continue;
      }
      const args = object(frame.args || {});
      const operation = text(frame.operation, "operación");
      running.set(id, {
        recordingId:
          typeof args.recordingId === "string" ? args.recordingId : undefined,
        abort: new AbortController(),
      });
      void context.run(id, async () => {
        try {
          const result = await execute(operation, args);
          await send({ type: "result", id, value: result ?? null });
        } catch (error) {
          await send({ type: "error", id, message: message(error) });
        } finally {
          running.delete(id);
        }
      });
    }
  } finally {
    for (const task of running.values()) task.abort.abort();
    for (const waiter of pending.values())
      waiter.reject(Error("El host cerró el canal"));
    for (const worker of workers.values()) worker.terminate();
  }
  await writing;
}
try {
  if (Deno.args.includes("--worker")) await workerProcess();
  else await main();
} catch (error) {
  await Deno.stderr.write(encoder.encode(`${message(error)}\n`));
  Deno.exitCode = 1;
}
