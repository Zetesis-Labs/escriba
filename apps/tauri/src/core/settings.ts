import type { Settings } from "../types";

export function abbreviatedPath(path: string, home: string | null) {
  if (!home) return path;
  const root = home.replace(/\/+$/, "");
  if (path === root) return "~";
  return path.startsWith(`${root}/`) ? `~${path.slice(root.length)}` : path;
}

export type JobHistoryChoice = "7" | "30" | "90" | "always";

export const jobHistoryOptions: { value: JobHistoryChoice; label: string }[] = [
  { value: "7", label: "7 días" },
  { value: "30", label: "30 días" },
  { value: "90", label: "90 días" },
  { value: "always", label: "Siempre" },
];

export function jobHistoryChoice(settings: Pick<Settings, "jobHistoryDays">): JobHistoryChoice {
  if (settings.jobHistoryDays === undefined) return "7";
  if (settings.jobHistoryDays === null) return "always";
  return String(settings.jobHistoryDays) as JobHistoryChoice;
}

export function jobHistoryDays(choice: JobHistoryChoice) {
  return choice === "always" ? null : Number(choice);
}
