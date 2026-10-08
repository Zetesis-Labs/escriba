import {
  aborted,
  message,
  object,
  type RuntimeRunner,
  type WorkerTask,
  type WorkerContext,
} from "./contracts";
export interface WorkerPort {
  postMessage(value: unknown): void;
  terminate(): void;
  onmessage: ((event: MessageEvent) => void) | null;
  onerror: ((event: ErrorEvent) => void) | null;
  onmessageerror: ((event: MessageEvent) => void) | null;
}
export function createWorkerRunner(
  factory: () => WorkerPort = () =>
    new Worker(new URL("./worker.ts", import.meta.url), { type: "module" }),
): RuntimeRunner {
  return {
    run(task: WorkerTask, context: WorkerContext) {
      aborted(context.signal);
      return new Promise((resolve, reject) => {
        const worker = factory();
        const lifetime = new AbortController();
        let finished = false;
        const pending = new Set<number>();
        const finish = (error?: Error, value?: unknown) => {
          if (finished) return;
          finished = true;
          lifetime.abort();
          clearTimeout(timer);
          context.signal?.removeEventListener("abort", cancel);
          worker.terminate();
          if (error) reject(error);
          else resolve(value);
        };
        const cancel = () =>
          finish(new DOMException("Proceso cancelado", "AbortError"));
        let timer: ReturnType<typeof setTimeout>;
        let remaining = context.timeoutMs ?? 10000;
        let started = performance.now();
        const pause = () => {
          clearTimeout(timer);
          remaining = Math.max(0, remaining - (performance.now() - started));
        };
        const arm = () => {
          clearTimeout(timer);
          started = performance.now();
          if (!finished)
            timer = setTimeout(
              () => finish(Error("La receta excedió el tiempo permitido")),
              remaining,
            );
        };
        arm();
        context.signal?.addEventListener("abort", cancel, { once: true });
        worker.onerror = (e) => finish(Error(e.message || "Falló el Worker"));
        worker.onmessageerror = () =>
          finish(Error("Mensaje del Worker no válido"));
        worker.onmessage = async (event) => {
          if (finished) return;
          try {
            const value = object(event.data);
            if (value.type === "result") {
              if (pending.size)
                throw Error("El Worker terminó con operaciones pendientes");
              finish(undefined, value.value);
              return;
            }
            if (value.type === "error") {
              finish(Error(String(value.message)));
              return;
            }
            if (
              value.type !== "call" ||
              typeof value.id !== "number" ||
              !Number.isSafeInteger(value.id) ||
              pending.has(value.id) ||
              pending.size >= 100 ||
              typeof value.operation !== "string"
            )
              throw Error("Solicitud del Worker no válida");
            if (!pending.size) pause();
            pending.add(value.id);
            try {
              aborted(context.signal);
              const response = await context.call(
                value.operation,
                value.payload,
                lifetime.signal,
              );
              aborted(context.signal);
              if (!finished)
                worker.postMessage({
                  type: "resolve",
                  id: value.id,
                  value: response,
                });
            } catch (error) {
              if (!finished)
                worker.postMessage({
                  type: "reject",
                  id: value.id,
                  message: message(error),
                });
            } finally {
              pending.delete(value.id);
              if (!pending.size) arm();
            }
          } catch (error) {
            finish(Error(message(error)));
          }
        };
        worker.postMessage({ type: "start", task });
      });
    },
  };
}
