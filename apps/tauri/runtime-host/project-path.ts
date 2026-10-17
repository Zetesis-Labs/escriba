import { lstat, readlink, realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

export function filesystemPath(path: string) {
  if (process.platform !== "win32") return path;
  if (path.startsWith("\\\\?\\UNC\\")) return `\\\\${path.slice(8)}`;
  return /^\\\\\?\\[a-z]:\\/i.test(path) ? path.slice(4) : path;
}

export function metafilePath(input: string) {
  const otherDrive = process.platform === "win32" && /^(?:\.\.\/)*([a-z]:\/.*)$/i.exec(input);
  return resolve(otherDrive ? otherDrive[1] : input);
}

export function projectCanonicalPath(roots: string[], native: (path: string) => Promise<string> = realpath) {
  const anchors = roots.map((root) => resolve(filesystemPath(root))).sort((a, b) => b.length - a.length);
  async function confined(path: string, links = 0): Promise<string> {
    if (links > 40) throw Error("Demasiados enlaces en la ruta del proyecto");
    const absolute = resolve(filesystemPath(path));
    const root = anchors.find((anchor) => {
      const entry = relative(anchor, absolute);
      return !isAbsolute(entry) && entry !== ".." && !entry.startsWith(`..${sep}`);
    });
    if (!root) throw Error("Fuente enlazada fuera del proyecto o de las dependencias incluidas");
    const metadata = await lstat(root);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw Error("La raíz debe ser una carpeta real");
    const parts = relative(root, absolute).split(sep).filter(Boolean);
    let current = root;
    for (const [index, part] of parts.entries()) {
      current = join(current, part);
      if ((await lstat(current)).isSymbolicLink()) {
        const target = filesystemPath(await readlink(current));
        return confined(resolve(dirname(current), target, ...parts.slice(index + 1)), links + 1);
      }
    }
    return current;
  }
  return async (path: string) => {
    try { return filesystemPath(await native(filesystemPath(path))); }
    catch (error) {
      if (process.platform !== "win32" || (error as NodeJS.ErrnoException).code !== "EPERM") throw error;
      // Bun realpath consulta MountPointManager; las raíces ya llegan canónicas desde Rust.
      return confined(path);
    }
  };
}
