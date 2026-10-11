import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { call, desktop } from "../api";
import type { JSONObject, JobState, ProcessOptions } from "../types";
import type { ConnectorEditorRequest, ConnectorEditorResult } from "@escriba/conectores";
import { builtinProviders, run as runBuiltinConnector } from "@escriba/conectores";
let jobs: JobState[] = [];
let revision = 0;
const failures = new Set<(message: string) => void>();
const subscribers = new Set<() => void>();
let listening: Promise<UnlistenFn> | undefined;
function update(value: JobState[]) {
  revision++;
  jobs = value;
  for (const listener of subscribers) listener();
}
function observe() {
  if (!desktop || listening) return;
  listening = listen<JobState[]>("escriba://jobs", (event) =>
    update(event.payload),
  );
  void listening
    .then(async (unlisten) => {
      const observed = revision;
      try {
        const value = await call<JobState[]>("runtime_jobs");
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
export const connectorEditor = async (operation: "describe" | "action" | "validate", request: ConnectorEditorRequest): Promise<ConnectorEditorResult> => {
  if (desktop) return run<ConnectorEditorResult>("connectorEditor", { operation, request });
  if (operation === "action" || !builtinProviders.some((provider) => provider.id === request.providerId))
    throw Error("Esta acción sólo está disponible en Escriba.");
  const result = await runBuiltinConnector({ operation, provider: request.providerId, config: request.configuration, state: request.state });
  return result as ConnectorEditorResult;
};
export function cancelProcessing(recordingId: string) {
  return call<void>("runtime_cancel", { recordingId });
}
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
