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

const CORRECTIONS = ["correccion", "manual"];

export function withCorrectionCriteria<T extends Pick<Version, "backend" | "inputs">>(versions: readonly T[]): T[] {
  let criteria: JSONObject | undefined;
  return versions.map((version) => {
    if (!CORRECTIONS.includes(version.backend)) {
      criteria = version.inputs;
      return version;
    }
    return version.inputs || !criteria ? version : { ...version, inputs: criteria };
  });
}

export function reusableTranscription(
  version: Pick<Version, "inputs" | "hasVoices">,
  inputs: JSONObject,
): boolean {
  return transcriptionCriteriaKey(version.inputs) === transcriptionCriteriaKey(inputs)
    && (inputs.diarize !== true || version.hasVoices === true);
}
