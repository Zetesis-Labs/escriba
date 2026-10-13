import { errorCode, message, json, object, text, type RuntimeHost } from "./contracts";
import { capacity, LANES, type JobResult, type Lane } from "./library/jobs";
import type { Library } from "./library/library";
import type { Queue } from "./library/queue";
import { notify, type Tasks } from "./domain";
import { finished } from "./notifications";

export interface LaneDependencies {
  queue: Queue;
  library: Library;
  host: RuntimeHost;
  tasks: Tasks;
  execute(operation: string, args: Record<string, unknown>): Promise<unknown>;
  log(message: string): void;
}
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
async function runJob(deps: LaneDependencies, id: string, recordingId: string | undefined, operation: string, args: Record<string, unknown>): Promise<JobResult> {
  try {
    const value = await deps.tasks.run(id, recordingId, () => deps.execute(operation, args));
    return { ok: true, value: json(value ?? null) };
  } catch (error) {
    return { ok: false, error: { code: errorCode(error), message: message(error) } };
  }
}
async function serve(deps: LaneDependencies, lane: Lane, stopped: { value: boolean }) {
  const { queue, library } = deps;
  while (!stopped.value) {
    try {
      if (lane === "inference") await queue.automatic();
      const job = await queue.claim(lane);
      if (job === undefined) {
        await queue.idle(lane);
        continue;
      }
      const entry = object(job);
      const id = text(entry.id, "id");
      const recordingId = typeof entry.recordingId === "string" ? entry.recordingId : undefined;
      const result = await runJob(deps, id, recordingId, text(entry.operation, "operation"), object(entry.args ?? {}));
      let notice;
      try {
        notice = finished(job, recordingId === undefined ? null : await library.recording(recordingId), result, library.settingsJson());
      } catch (error) {
        deps.log(message(error));
      }
      if ((await queue.finish(id, result)) && notice) await notify(deps.host, notice).catch((error) => deps.log(message(error)));
    } catch (error) {
      deps.log(message(error));
      await sleep(5000);
    }
  }
}
export function startLanes(deps: LaneDependencies): () => void {
  const stopped = { value: false };
  for (const lane of LANES) for (let index = 0; index < capacity(lane); index++) void serve(deps, lane, stopped);
  return () => {
    stopped.value = true;
    deps.queue.wakeAll();
  };
}
export function startHistorySweep(queue: Queue, log: (message: string) => void): () => void {
  let last: number | undefined;
  const sweep = async () => {
    const now = Date.now();
    if (last !== undefined && now - last < 86_400_000) return;
    last = now;
    try {
      await queue.purge(now);
    } catch (error) {
      log(`No se pudo repasar el historial de trabajos: ${message(error)}`);
    }
  };
  void sweep();
  const timer = setInterval(() => void sweep(), 3_600_000);
  return () => clearInterval(timer);
}
