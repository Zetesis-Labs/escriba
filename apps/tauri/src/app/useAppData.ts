import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useState } from "react";
import { desktop, library } from "../api";
import { demoSnapshot } from "./demo";
import { errorText } from "../mac/native";
import { getJobs, subscribeJobs } from "../runtime";
import type { JobState, Snapshot } from "../types";

export const demo = !desktop && new URLSearchParams(window.location.search).get("demo") === "1";

export function useAppData() {
  const [data, setData] = useState<Snapshot | null>(demo ? ((window as { escribaDemo?: Snapshot }).escribaDemo ?? demoSnapshot) : null);
  const [jobs, setJobs] = useState<JobState[]>([]);
  const [problem, setProblem] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!desktop) return;
    try {
      setData(await library());
      setProblem(null);
    } catch (failure) {
      setProblem(errorText(failure));
    }
  }, []);

  useEffect(() => {
    if (!desktop) return;
    void refresh();
    let unlisten: (() => void) | undefined;
    void listen("escriba://changed", () => void refresh()).then((stop) => {
      unlisten = stop;
    });
    const unsubscribe = subscribeJobs(() => setJobs(getJobs()), setProblem);
    setJobs(getJobs());
    const fallback = window.setInterval(() => void refresh(), 60_000);
    return () => {
      unlisten?.();
      unsubscribe();
      window.clearInterval(fallback);
    };
  }, [refresh]);

  return { data, jobs, problem, refresh };
}
