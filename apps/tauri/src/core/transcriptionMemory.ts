import type { JSONObject, Version } from "../types";

export function normalizeTranscriptionInputs(inputs: JSONObject): JSONObject {
  return inputs.diarize === false && "speakers" in inputs && inputs.speakers !== null
    ? { ...inputs, speakers: null }
    : inputs;
}

export function transcriptionCriteriaKey(inputs?: JSONObject): string {
  const normalized = normalizeTranscriptionInputs(inputs || {});
  return JSON.stringify(normalized, Object.keys(normalized).sort());
}

export function reusableTranscription(
  version: Pick<Version, "inputs" | "hasVoices">,
  inputs: JSONObject,
): boolean {
  return transcriptionCriteriaKey(version.inputs) === transcriptionCriteriaKey(inputs)
    && (inputs.diarize !== true || version.hasVoices === true);
}
