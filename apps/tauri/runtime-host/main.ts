import { AsyncLocalStorage } from "node:async_hooks";
import process from "node:process";
import { createRequire, isBuiltin } from "node:module";
import { buildProject } from "./project";
import { createRuntime } from "../src/runtime/controller";
import {
  createWorkerRunner,
  type WorkerPort,
} from "../src/runtime/workerClient";
import { object, text, message, errorCode, protocolError, jsonObject, json } from "../src/runtime/contracts";
import { createCommands, isOrigin, registerControllerCommands } from "../src/runtime/commands";
import { registerDomainCommands, warnAboutUnusable, type Tasks } from "../src/runtime/domain";
import { startHistorySweep, startLanes } from "../src/runtime/lanes";
import { fileCredentials } from "../src/runtime/credentials";
import { Library } from "../src/runtime/library/library";
import { Queue } from "../src/runtime/library/queue";
import type { NativeStatus, ProcessOptions } from "../src/types";
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
  writing = writing.then(() => new Promise<void>((resolve, reject) => {
    process.stdout.write(data, (error) => error ? reject(error) : resolve());
  }));
  return writing;
}
async function* frames() {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let parts: Uint8Array[] = [];
  let size = 0;
  for await (const bytes of process.stdin) {
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
  const require = createRequire(import.meta.url);
  Object.defineProperty(globalThis, "__escribaRequire", {
    value: (specifier: string) => {
      if (!isBuiltin(specifier)) throw Error(`Módulo no incluido en el paquete: ${specifier}`);
      return require(specifier);
    },
    writable: false,
    configurable: false,
  });
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
  const dataPath = process.env.ESCRIBA_DATA;
  if (!dataPath) throw Error("Falta la carpeta de datos (ESCRIBA_DATA)");
  const library = await Library.open(dataPath);
  try {
    await serve(library, dataPath);
  } finally {
    await library.close();
  }
}
async function serve(library: Library, dataPath: string) {
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
  const commands = createCommands();
  const host = {
    call(method: string, params: Record<string, unknown> = {}) {
      if (closing) return Promise.reject(closing);
      const taskId = context.getStore();
      if (taskId !== undefined && running.get(taskId)?.abort.signal.aborted)
        return Promise.reject(
          new DOMException("Proceso cancelado", "AbortError"),
        );
      if (commands.owns(method)) return commands.dispatch(method, params, "shell");
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
  const emit = (event: string, value?: unknown) => {
    void send({ type: "event", event, value: value ?? null });
  };
  const log = (text: string) => {
    try {
      library.log({ message: text, level: "error" });
    } catch (error) {
      process.stderr.write(`${text}: ${message(error)}\n`);
    }
  };
  const tasks: Tasks = {
    current: () => {
      const id = context.getStore();
      return typeof id === "string" ? id : undefined;
    },
    run(id, recordingId, body) {
      if (running.has(id)) return Promise.reject(Error("ID de ejecución repetido"));
      running.set(id, { recordingId, abort: new AbortController() });
      return context.run(id, body).finally(() => {
        running.delete(id);
      });
    },
    cancel(id) {
      const task = running.get(id);
      if (!task) return;
      context.run(id, () => {
        task.abort.abort();
        for (const [callId, waiter] of pending) {
          if (waiter.taskId === id) {
            pending.delete(callId);
            waiter.reject(new DOMException("Proceso cancelado", "AbortError"));
          }
        }
        if (task.recordingId) runtime.cancelProcessing(task.recordingId);
      });
    },
  };
  const queue = await Queue.open(library);
  runtime.subscribeJobs(() => {
    void queue.stages(runtime.getJobs()).catch((error) => log(message(error)));
  });
  library.subscribe(() => emit("status", { recordings: library.index().recordings.length, jobs: queue.visible() }));
  async function execute(operation: string, args: Record<string, unknown>) {
    switch (operation) {
      case "notificationProblems":
        return runtime.notificationProblems(object(args.status) as NativeStatus);
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
      case "connectorEditor": {
        const operation = args.operation;
        if (operation !== "describe" && operation !== "action" && operation !== "validate") throw Error("Operación del editor inválida");
        const input = object(args.request);
        return runtime.connectorEditor(operation, {
          providerId: text(input.providerId, "proveedor"),
          ...(typeof input.accountId === "string" ? { accountId: input.accountId } : {}),
          configuration: jsonObject(input.configuration),
          ...(input.state === undefined ? {} : { state: jsonObject(input.state) }),
          ...(typeof input.action === "string" ? { action: input.action } : {}),
          ...(input.value === undefined ? {} : { value: json(input.value) }),
        });
      }
      case "getRecipeSchema":
        return runtime.getRecipeSchema(text(args.recipeId, "receta"));
      case "rebuildProject":
        return runtime.rebuildProject({ loadOnly: args.loadOnly === true });
      default:
        throw Error(`Operación no permitida: ${operation}`);
    }
  }
  const domain = {
    library,
    queue,
    host,
    credentials: fileCredentials(dataPath),
    tasks,
    execute,
    notificationProblems: (status: NativeStatus) => runtime.notificationProblems(status),
    emit,
    log,
  };
  registerControllerCommands(commands, { host, dataPath, credentials: domain.credentials, emit });
  registerDomainCommands(commands, domain);
  void (async () => {
    for (;;) {
      await queue.changed.notified();
      if (closing) return;
      emit("jobs", queue.visible());
      emit("changed");
    }
  })();
  const stopLanes = startLanes(domain);
  const stopSweep = startHistorySweep(queue, log);
  await send({ type: "ready", protocolVersion: 1 });
  void warnAboutUnusable(domain).catch((error) => log(message(error)));
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
        else waiter.reject(protocolError(frame));
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
        tasks.cancel(String(id));
        continue;
      }
      if (frame.type !== "command") throw Error("Trama de protocolo no permitida");
      if (running.has(id)) {
        await send({ type: "error", id, message: "ID de ejecución repetido" });
        continue;
      }
      if (!isOrigin(frame.origin)) {
        await send({ type: "error", id, message: "Origen del comando no permitido" });
        continue;
      }
      const origin = frame.origin;
      const params = object(frame.params ?? {});
      running.set(id, { abort: new AbortController() });
      void context.run(id, async () => {
        try {
          const result = await commands.dispatch(text(frame.method, "método"), params, origin);
          if (!closing) await send({ type: "result", id, value: result ?? null });
        } catch (error) {
          if (!closing) await send({ type: "error", id, message: message(error), code: errorCode(error) });
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
        send({ type: "error", id, message: closing!.message, code: "runtime_unavailable" }),
      ),
    );
    throw error;
  } finally {
    closing ??= Error(channelError ? message(channelError) : "El host cerró el canal");
    stopLanes();
    stopSweep();
    for (const waiter of pending.values())
      waiter.reject(closing);
    pending.clear();
    for (const task of running.values()) task.abort.abort();
    for (const worker of workers.values()) worker.terminate();
    workers.clear();
    workerTasks.clear();
    queue.changed.notifyWaiters();
  }
  await writing;
}
try {
  const projectBuild = process.argv.indexOf("--project-build");
  if (projectBuild >= 0) {
    const root = process.argv[projectBuild + 1];
    const vendor = process.argv[projectBuild + 2];
    if (!root || !vendor) throw Error("Falta el proyecto o las dependencias incluidas");
    await buildProject(root, vendor);
  } else if (process.argv.includes("--worker")) await workerProcess();
  else await main();
} catch (error) {
  process.stderr.write(`${message(error)}\n`);
  process.exitCode = 1;
}
