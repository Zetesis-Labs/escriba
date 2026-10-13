import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

export interface CredentialStore {
  read(key: string): Promise<string | undefined>;
  save(key: string, value: string): Promise<void>;
}
export function safeId(value: string): string {
  if (
    !value ||
    value.length >= 200 ||
    !/^[A-Za-z0-9._-]+$/.test(value) ||
    value === "." ||
    value === ".."
  )
    throw Error("Identificador inválido");
  return value;
}
export const credentialPath = (root: string, key: string) =>
  join(root, "secrets", `${safeId(key)}.token`);
export function fileCredentials(root: string): CredentialStore {
  return {
    async read(key) {
      try {
        return await readFile(credentialPath(root, key), "utf8");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
        throw Error(`No se puede leer la credencial: ${(error as Error).message}`);
      }
    },
    async save(key, value) {
      const path = credentialPath(root, key);
      const trimmed = value.trim();
      if (!trimmed) {
        await rm(path, { force: true });
        return;
      }
      await mkdir(join(root, "secrets"), { recursive: true, mode: 0o700 });
      const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
      await writeFile(temporary, trimmed, { mode: 0o600 });
      await rename(temporary, path);
    },
  };
}
export function memoryCredentials(initial: Record<string, string> = {}): CredentialStore {
  const values = new Map(Object.entries(initial));
  return {
    async read(key) {
      return values.get(safeId(key));
    },
    async save(key, value) {
      const trimmed = value.trim();
      if (trimmed) values.set(safeId(key), trimmed);
      else values.delete(safeId(key));
    },
  };
}
