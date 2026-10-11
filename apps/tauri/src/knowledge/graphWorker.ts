import ELK, { type ElkNode } from "elkjs/lib/elk-api";

export function graphWorker(worker: Worker) {
  const pending = new Set<(error: Error) => void>();
  let failure: Error | null = null;
  const stop = (error: Error) => {
    if (failure) return;
    failure = error;
    worker.removeEventListener("error", onError);
    worker.removeEventListener("messageerror", onMessageError);
    worker.terminate();
    for (const reject of pending) reject(error);
    pending.clear();
  };
  const onError = (event: ErrorEvent) => {
    event.preventDefault();
    stop(new Error(event.message || "No se pudo iniciar el motor del mapa."));
  };
  const onMessageError = () => stop(new Error("No se pudo leer la respuesta del motor del mapa."));
  worker.addEventListener("error", onError);
  worker.addEventListener("messageerror", onMessageError);
  const engine = new ELK({ workerFactory: () => worker });
  return {
    layout(input: ElkNode): Promise<ElkNode> {
      if (failure) return Promise.reject(failure);
      return new Promise((resolve, reject) => {
        pending.add(reject);
        engine.layout(input).then(
          (result) => { pending.delete(reject); resolve(result); },
          (error: unknown) => { pending.delete(reject); reject(error); },
        );
      });
    },
    dispose: () => stop(new Error("Se cerró el motor del mapa.")),
  };
}
