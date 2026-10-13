import type { Json } from "./json";
import * as jobs from "./jobs";
import type { Library } from "./library";

export class Notify {
  private waiters: (() => void)[] = [];
  private pending = false;
  notifyOne() {
    const waiter = this.waiters.shift();
    if (waiter) waiter();
    else this.pending = true;
  }
  notifyWaiters() {
    const waiters = this.waiters.splice(0);
    for (const waiter of waiters) waiter();
  }
  notified(): Promise<void> {
    if (this.pending) {
      this.pending = false;
      return Promise.resolve();
    }
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
export class Queue {
  private readonly wakes: Record<jobs.Lane, Notify> = { inference: new Notify(), io: new Notify() };
  readonly changed = new Notify();
  private constructor(private readonly library: Library) {}

  static async open(library: Library): Promise<Queue> {
    await library.recoverJobs();
    return new Queue(library);
  }
  wake(lane: jobs.Lane) {
    this.wakes[lane].notifyOne();
  }
  wakeAll() {
    for (const lane of jobs.LANES) this.wake(lane);
  }
  async idle(lane: jobs.Lane) {
    await Promise.race([this.wakes[lane].notified(), sleep(5000)]);
  }
  enqueue(operation: string, args: Json) {
    return this.enqueueWithOrigin(operation, args, false);
  }
  enqueueAutomatic(recording: string) {
    return this.enqueueWithOrigin("processRecording", { recordingId: recording, options: { force: false } }, true);
  }
  private async enqueueWithOrigin(operation: string, args: Json, automatic: boolean): Promise<string> {
    const [id, lane] = await this.library.enqueueJob(operation, args, automatic);
    this.wake(lane);
    this.changed.notifyWaiters();
    return id;
  }
  history(query: jobs.HistoryQuery) {
    return this.library.jobHistory(query);
  }
  visible(): Json[] {
    return this.library.activeJobs();
  }
  async automatic() {
    if (await this.library.enqueueAutomaticJobs()) {
      this.wake("inference");
      this.changed.notifyWaiters();
    }
  }
  async claim(lane: jobs.Lane): Promise<Json | undefined> {
    const claimed = await this.library.claimJob(lane, Date.now());
    if (claimed.kind === "empty") return undefined;
    this.changed.notifyWaiters();
    this.wake(lane);
    return claimed.kind === "job" ? claimed.job : undefined;
  }
  async finish(id: string, result: jobs.JobResult): Promise<boolean> {
    const lane = await this.library.finishJob(id, result);
    if (lane === undefined) return false;
    this.changed.notifyWaiters();
    this.wake(lane);
    return true;
  }
  async stages(value: Json) {
    await this.library.jobStages(value);
    this.changed.notifyWaiters();
  }
  async purge(now: number): Promise<number> {
    const count = await this.library.purgeJobs(now);
    if (count > 0) this.changed.notifyWaiters();
    return count;
  }
  async relaunch(id: string): Promise<string> {
    const [next, lane] = await this.library.relaunchJob(id);
    this.wake(lane);
    this.changed.notifyWaiters();
    return next;
  }
  async cancel(recording: string): Promise<jobs.Cancellation> {
    const cancellation = await this.library.cancelJobs(recording);
    this.changed.notifyWaiters();
    return cancellation;
  }
  async wait(id: string): Promise<Json> {
    for (;;) {
      const changed = this.changed.notified();
      const job = await this.library.job(id);
      if (!job) throw Error("Trabajo desconocido");
      if (job.state === "succeeded") return job.result ?? null;
      if (job.state === "failed" || job.state === "cancelled") throw Error(job.error ?? "El trabajo falló");
      await Promise.race([changed, sleep(2000)]);
    }
  }
}
