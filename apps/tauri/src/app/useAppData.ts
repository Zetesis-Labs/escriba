import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useState } from "react";
import { library } from "../api";
import { errorText } from "../mac/native";
import { getJobs, subscribeJobs } from "../runtime";
import type { Job } from "../runtime/library/jobs";
import type { Snapshot } from "../types";

export function useAppData() {
  const [data, setData] = useState<Snapshot | null>(null);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [problem, setProblem] = useState<string | null>(null);
  const [jobsProblem, setJobsProblem] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setData(await library());
      setProblem(null);
    } catch (failure) {
      setProblem(errorText(failure));
    }
  }, []);

  useEffect(() => {
    void refresh();
    let unlisten: (() => void) | undefined;
    void listen("escriba://changed", () => void refresh()).then((stop) => {
      unlisten = stop;
    });
    const unsubscribe = subscribeJobs(
      () => {
        setJobs(getJobs());
        setJobsProblem(null);
      },
      (message) => {
        setProblem(message);
        setJobsProblem(message);
      },
    );
    setJobs(getJobs());
    const fallback = window.setInterval(() => void refresh(), 60_000);
    return () => {
      unlisten?.();
      unsubscribe();
      window.clearInterval(fallback);
    };
  }, [refresh]);

  return { data, jobs, jobsProblem, problem, refresh };
}
