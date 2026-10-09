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
const MAX_FRAME = 32 * 1024 * 1024;
let writing = Promise.resolve();
function send(value: unknown) {
  const data = encoder.encode(`${JSON.stringify(value)}\n`);
  if (data.length - 1 > MAX_FRAME)
    return Promise.reject(Error("Trama de salida demasiado grande (límite 32 MiB)"));
  writing = writing.then(async () => {
    let offset = 0;
    while (offset < data.length)
      offset += await Deno.stdout.write(data.subarray(offset));
  });
  return writing;
}
async function* frames() {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let parts: Uint8Array[] = [];
  let size = 0;
  for await (const bytes of Deno.stdin.readable) {
    let start = 0;
    for (let index = 0; index < bytes.length; index++) {
      if (bytes[index] !== 10) continue;
      const piece = bytes.subarray(start, index);
      size += piece.length;
      if (size > MAX_FRAME) throw Error("Trama de entrada demasiado grande (límite 32 MiB)");
      const line = new Uint8Array(size);
      let offset = 0;
      for (const part of parts) {
        line.set(part, offset);
        offset += part.length;
      }
      line.set(piece, offset);
      if (size) {
        let value: unknown;
        try {
          value = JSON.parse(decoder.decode(line));
        } catch {
          throw Error("Trama JSON inválida");
        }
        yield value;
      }
      parts = [];
      size = 0;
      start = index + 1;
    }
    const remainder = bytes.subarray(start);
    size += remainder.length;
    if (size > MAX_FRAME) throw Error("Trama de entrada demasiado grande (límite 32 MiB)");
    if (remainder.length) parts.push(remainder);
  }
  if (size) throw Error("Trama incompleta al cerrar stdin");
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
      void send(value).catch(async (error) => {
        await send({ type: "error", message: message(error) });
      });
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
  let closing: Error | undefined;
  let sequence = 0;
  const host = {
    call(method: string, params: Record<string, unknown> = {}) {
      if (closing) return Promise.reject(closing);
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
        void send({ type: "worker_send", id, value }).catch((error) => {
          port.onerror?.({ message: message(error) } as ErrorEvent);
        });
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
    void send({ type: "worker_create", id, taskId: context.getStore() }).catch((error) => {
      port.onerror?.({ message: message(error) } as ErrorEvent);
    });
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
  let channelError: unknown;
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
          if (!closing) await send({ type: "result", id, value: result ?? null });
        } catch (error) {
          if (!closing) await send({ type: "error", id, message: message(error) });
        } finally {
          running.delete(id);
        }
      });
    }
  } catch (error) {
    channelError = error;
    closing = Error(`Canal de protocolo: ${message(error)}`);
    await Promise.all(
      [...running.keys()].map((id) =>
        send({ type: "error", id, message: closing!.message }),
      ),
    );
    throw error;
  } finally {
    closing ??= Error(channelError ? message(channelError) : "El host cerró el canal");
    for (const waiter of pending.values())
      waiter.reject(closing);
    pending.clear();
    for (const task of running.values()) task.abort.abort();
    for (const worker of workers.values()) worker.terminate();
    workers.clear();
    workerTasks.clear();
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
