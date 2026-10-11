import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { call } from "../api";

export type RecorderProblem = { message: string; denied: boolean };
export type RecordingState = {
  active: boolean;
  clock: string;
  recipeName: string | null;
  levels: number[];
  problem: RecorderProblem | null;
};
export type RecorderStatus = Pick<RecordingState, "active" | "problem">;

export const idleRecording: RecordingState = { active: false, clock: "00:00", recipeName: null, levels: [], problem: null };

function useRecordingEvents(apply: (state: RecordingState) => void) {
  useEffect(() => {
    let alive = true;
    let stop: (() => void) | undefined;
    void call<RecordingState>("recording_status").then((state) => alive && apply(state));
    void listen<RecordingState>("escriba://recording", (event) => apply(event.payload)).then((unlisten) => {
      if (alive) stop = unlisten;
      else unlisten();
    });
    return () => {
      alive = false;
      stop?.();
    };
  }, [apply]);
}

export function useRecording() {
  const [state, setState] = useState(idleRecording);
  useRecordingEvents(setState);
  return state;
}

const sameProblem = (a: RecorderProblem | null, b: RecorderProblem | null) => a?.message === b?.message && a?.denied === b?.denied;

export function useRecorderStatus() {
  const [status, setStatus] = useState<RecorderStatus>({ active: false, problem: null });
  const [apply] = useState(() => (state: RecordingState) =>
    setStatus((previous) =>
      previous.active === state.active && sameProblem(previous.problem, state.problem) ? previous : { active: state.active, problem: state.problem },
    ),
  );
  useRecordingEvents(apply);
  return status;
}

export const startRecording = (recipeId?: string) => call<RecordingState>("recording_start", recipeId ? { recipeId } : {});
export const stopRecording = () => call("recording_stop");
export const discardRecording = () => call("recording_cancel");
export const dismissRecorderProblem = () => call("recording_dismiss");
export const openMicrophoneSettings = () => call("open_privacy_settings", { pane: "microphone" });
