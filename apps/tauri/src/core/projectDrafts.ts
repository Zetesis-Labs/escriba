export interface ProjectDraft {
  source: string;
  saved: string;
}

export type ProjectDrafts = Record<string, ProjectDraft>;

type ProjectDraftAction =
  | { type: "loaded"; entry: string; source: string }
  | { type: "reloaded"; entry: string; source: string }
  | { type: "edited"; entry: string; source: string }
  | { type: "saved"; entry: string; source: string };

export function projectDrafts(): ProjectDrafts {
  return {};
}

export function projectDraft(drafts: ProjectDrafts, entry: string): ProjectDraft | undefined {
  return Object.hasOwn(drafts, entry) ? drafts[entry] : undefined;
}

export function updateProjectDrafts(drafts: ProjectDrafts, action: ProjectDraftAction): ProjectDrafts {
  const existing = projectDraft(drafts, action.entry);
  if (action.type === "loaded" || action.type === "reloaded") {
    if (action.type === "loaded" && existing) return drafts;
    return { ...drafts, [action.entry]: { source: action.source, saved: action.source } };
  }
  if (!existing) return drafts;
  return {
    ...drafts,
    [action.entry]: action.type === "edited"
      ? { ...existing, source: action.source }
      : { ...existing, saved: action.source },
  };
}

export interface ProjectFileNode {
  name: string;
  path: string;
  children?: ProjectFileNode[];
}

export function projectFileTree(files: string[]): ProjectFileNode[] {
  const roots: ProjectFileNode[] = [];
  for (const entry of [...files].sort((a, b) => a.localeCompare(b, "es"))) {
    const parts = entry.split("/");
    let level = roots;
    for (const [index, name] of parts.entries()) {
      const path = parts.slice(0, index + 1).join("/");
      let node = level.find((item) => item.path === path);
      if (!node) {
        node = index === parts.length - 1 ? { name, path } : { name, path, children: [] };
        level.push(node);
      }
      if (node.children) level = node.children;
    }
  }
  return roots;
}

export function unsavedProjectFiles(drafts: ProjectDrafts): string[] {
  return Object.entries(drafts)
    .filter(([, draft]) => draft.source !== draft.saved)
    .map(([entry]) => entry)
    .sort((a, b) => a.localeCompare(b, "es"));
}

export function dirtyProjectDrafts(drafts: ProjectDrafts): ProjectDrafts {
  return Object.fromEntries(Object.entries(drafts).filter(([, draft]) => draft.source !== draft.saved));
}

export function projectFileVisible(entry: string): boolean {
  return /\.(?:ts|tsx|js|mjs|cjs|json|md)$/.test(entry);
}

export function projectSaveArgs(entry: string, draft: ProjectDraft) {
  return { entry, source: draft.source, expectedSource: draft.saved };
}

export function projectCreateArgs(entry: string) {
  return { entry, source: "", createNew: true };
}

export function projectRevealPath(root: string, entry?: string): string {
  if (!entry || entry.startsWith("/") || entry.includes("\\") || entry.includes("\0")
    || entry.split("/").some((part) => !part || part === "." || part === ".."
      || [".git", ".escriba", "dist", "node_modules"].includes(part))) return root;
  return `${root.replace(/\/+$/, "")}/${entry}`;
}
