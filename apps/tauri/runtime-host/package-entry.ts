import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";

// Bun.resolveSync inside a compiled executable only finds a package's root index.js,
// not what its package.json exports or names as main; the builder resolves those here.

const CONDITIONS = ["bun", "import", "module", "default", "require"];

function target(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = target(item);
      if (found) return found;
    }
    return undefined;
  }
  if (value && typeof value === "object")
    for (const condition of CONDITIONS)
      if (condition in value) {
        const found = target((value as Record<string, unknown>)[condition]);
        if (found) return found;
      }
  return undefined;
}

function exported(exports: unknown, subpath: string): string | undefined {
  const map = exports && typeof exports === "object" && !Array.isArray(exports) ? (exports as Record<string, unknown>) : undefined;
  if (!map || !Object.keys(map).some((key) => key.startsWith("."))) return subpath === "." ? target(exports) : undefined;
  if (subpath in map) return target(map[subpath]);
  for (const [key, value] of Object.entries(map)) {
    const star = key.indexOf("*");
    if (star < 0) continue;
    const prefix = key.slice(0, star);
    const suffix = key.slice(star + 1);
    if (subpath.startsWith(prefix) && subpath.endsWith(suffix) && subpath.length >= key.length - 1)
      return target(value)?.replace("*", subpath.slice(prefix.length, subpath.length - suffix.length));
  }
  return undefined;
}

function file(path: string): string {
  for (const candidate of [path, `${path}.js`, join(path, "index.js")])
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  return path;
}

/** The file a bare specifier names from `directory`, or undefined if no node_modules above has the package. */
export function packageEntry(specifier: string, directory: string): string | undefined {
  const parts = specifier.split("/");
  const name = specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0]!;
  const subpath = `.${specifier.slice(name.length)}`;
  for (let current = directory; ; current = dirname(current)) {
    const root = join(current, "node_modules", name);
    const manifest = join(root, "package.json");
    if (existsSync(manifest)) {
      const value = JSON.parse(readFileSync(manifest, "utf8")) as { exports?: unknown; module?: string; main?: string };
      const entry =
        value.exports === undefined
          ? subpath === "."
            ? (value.module ?? value.main ?? "index.js")
            : subpath
          : exported(value.exports, subpath);
      if (entry === undefined) throw Error(`El paquete ${name} no exporta ${subpath}`);
      return file(join(root, entry));
    }
    if (dirname(current) === current) return undefined;
  }
}
