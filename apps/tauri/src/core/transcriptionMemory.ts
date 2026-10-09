import type { JSONObject, Version } from "../types";

export function transcriptionCriteriaKey(inputs?: JSONObject): string {
  return JSON.stringify(inputs || {}, Object.keys(inputs || {}).sort());
}

export function reusableTranscription(
  version: Pick<Version, "inputs" | "hasVoices">,
  inputs: JSONObject,
): boolean {
  return transcriptionCriteriaKey(version.inputs) === transcriptionCriteriaKey(inputs)
    && (inputs.diarize !== true || version.hasVoices === true);
}
