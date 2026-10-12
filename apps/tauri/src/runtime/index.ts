import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { call } from "../api";
import type { HistoryPage } from "../generated/HistoryPage";
import type { HistoryQuery } from "../generated/HistoryQuery";
import type { Job } from "../generated/Job";
import type { JSONObject, ProcessOptions } from "../types";
import type { ConnectorEditorRequest, ConnectorEditorResult } from "@escriba/conectores";
let jobs: Job[] = [];
let revision = 0;
const failures = new Set<(message: string) => void>();
const subscribers = new Set<() => void>();
let listening: Promise<UnlistenFn> | undefined;
function update(value: Job[]) {
  revision++;
  jobs = value;
  for (const listener of subscribers) listener();
}
function observe() {
  if (listening) return;
  listening = listen<Job[]>("escriba://jobs", (event) =>
    update(event.payload),
  );
  void listening
    .then(async (unlisten) => {
      const observed = revision;
      try {
        const value = await call<Job[]>("runtime_jobs");
        if (observed === revision) update(value);
      } catch (error) {
        unlisten();
        throw error;
      }
    })
    .catch((error) => {
      listening = undefined;
      for (const notify of failures)
        notify(`No se pudo observar trabajos: ${String(error)}`);
    });
}
const run = <T = unknown>(operation: string, args: Record<string, unknown>) =>
  call<T>("runtime_run", { operation, args });
export const processRecording = (
  recordingId: string,
  options?: ProcessOptions,
) => run("processRecording", { recordingId, options });
export const summarizeRecording = (recordingId: string, llm?: string) =>
  run("summarizeRecording", { recordingId, llm });
export const publishRecording = (recordingId: string, destinationId: string) =>
  run("publishRecording", { recordingId, destinationId });
export const unpublishRecording = (
  recordingId: string,
  destinationId: string,
) => run("unpublishRecording", { recordingId, destinationId });
export const previewDestination = (
  destinationId: string,
  recordingId?: string,
) => run<JSONObject>("previewDestination", { destinationId, recordingId });
export const discoverDestination = (destinationId: string) =>
  run<JSONObject>("discoverDestination", { destinationId });
export const validateDestination = (destinationId: string) =>
  run<JSONObject>("validateDestination", { destinationId });
export const getRecipeSchema = (recipeId: string) =>
  run<JSONObject | null>("getRecipeSchema", { recipeId });
export const rebuildProject = () => run("rebuildProject", {});
export const connectorEditor = (operation: "describe" | "action" | "validate", request: ConnectorEditorRequest) =>
  run<ConnectorEditorResult>("connectorEditor", { operation, request });
export function cancelProcessing(recordingId: string) {
  return call<void>("runtime_cancel", { recordingId });
}
export const jobHistory = (query: HistoryQuery) => call<HistoryPage>("runtime_history", query);
export const relaunchJob = (id: string) => call<{ id: string }>("runtime_relaunch", { id });
export const getJobs = () => jobs.map((job) => ({ ...job }));
export function subscribeJobs(
  listener: () => void,
  onError?: (message: string) => void,
) {
  if (onError) failures.add(onError);
  subscribers.add(listener);
  observe();
  return () => {
    subscribers.delete(listener);
    if (onError) failures.delete(onError);
  };
}
