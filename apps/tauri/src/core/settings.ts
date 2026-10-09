export function abbreviatedPath(path: string, home: string | null) {
  if (!home) return path;
  const root = home.replace(/\/+$/, "");
  if (path === root) return "~";
  return path.startsWith(`${root}/`) ? `~${path.slice(root.length)}` : path;
}

export function importReport(report: { recordings: number; audioMissing: number; settingsImported?: boolean }) {
  const notes = report.recordings === 1 ? "1 nota importada" : `${report.recordings} notas importadas`;
  const missing = report.audioMissing === 0 ? "" : report.audioMissing === 1 ? ". 1 sin audio" : `. ${report.audioMissing} sin audio`;
  return `${notes}${missing}.`;
}
