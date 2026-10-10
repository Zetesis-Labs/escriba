export function abbreviatedPath(path: string, home: string | null) {
  if (!home) return path;
  const root = home.replace(/\/+$/, "");
  if (path === root) return "~";
  return path.startsWith(`${root}/`) ? `~${path.slice(root.length)}` : path;
}
