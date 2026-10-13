import { createHash } from "node:crypto";
import { closeSync, fsyncSync, linkSync, lstatSync, openSync, readFileSync, readSync, realpathSync, rmSync, statSync, unlinkSync, writeSync } from "node:fs";
import { basename, dirname, extname, join } from "node:path";
import { newId, rfc3339 } from "./json";
import type { LibraryData } from "./model";
import { audioDeletion, type AudioDeletion } from "./persistence";

export const AUDIO_EXTENSIONS = ["m4a", "mp3", "wav", "aac", "flac", "ogg", "oga", "opus", "mp4", "aiff", "aif", "caf", "webm", "mov"];

export interface StagedAudio {
  root: string;
  source: string;
  temp: string;
  hash: string;
  digest: Buffer;
  ext: string;
  captureDate?: Date;
  discard(): void;
}
export const importCreatedAt = (captureDate: Date | undefined, importedAt: Date) => rfc3339(captureDate ?? importedAt);

export function fileHash(path: string): Buffer {
  return createHash("sha256").update(readFileSync(path)).digest();
}
export function stageAudio(root: string, source: string, recoveredCapture: boolean): StagedAudio {
  let metadata;
  try {
    metadata = statSync(source);
  } catch (error) {
    throw Error(`No se puede leer ${source}: ${(error as Error).message}`);
  }
  if (!metadata.isFile() || metadata.size === 0) throw Error("El audio está vacío o no es un archivo");
  const captureDate = recoveredCapture ? metadata.mtime : undefined;
  const ext = extname(source).replace(/^\./, "").toLowerCase();
  if (!AUDIO_EXTENSIONS.includes(ext)) throw Error("Formato de audio no admitido");
  const temp = join(root, "audio", `.${newId()}.import`);
  const input = openSync(source, "r");
  const output = openSync(temp, "wx", 0o600);
  const hash = createHash("sha256");
  const discard = () => rmSync(temp, { force: true });
  try {
    const buffer = Buffer.alloc(65536);
    for (;;) {
      const count = readSync(input, buffer, 0, buffer.length, null);
      if (count === 0) break;
      writeSync(output, buffer, 0, count);
      hash.update(buffer.subarray(0, count));
    }
    const after = statSync(source);
    if (after.size !== metadata.size || after.mtimeMs !== metadata.mtimeMs) throw Error("El audio cambió durante la copia; espera a que termine de grabarse");
    fsyncSync(output);
  } catch (error) {
    closeSync(input);
    closeSync(output);
    discard();
    throw error;
  }
  closeSync(input);
  closeSync(output);
  const digest = hash.digest();
  return { root, source, temp, hash: digest.toString("hex"), digest, ext, ...(captureDate ? { captureDate } : {}), discard };
}
export function syncDirectory(path: string) {
  const fd = openSync(path, "r");
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}
export function audioCopyRoot(root: string): string {
  const path = join(root, "audio");
  let metadata;
  try {
    metadata = lstatSync(path);
  } catch (error) {
    throw Error((error as Error).message);
  }
  if (!metadata.isDirectory()) throw Error("Carpeta de copias de audio inválida");
  return realpathSync(path);
}
export function referencesAudio(data: LibraryData, copy: string): boolean {
  for (const record of data.recordings) {
    const paths = [record.source, record.status !== "discarded" ? record.audioPath : undefined];
    for (const path of paths) {
      if (typeof path !== "string" || !path) continue;
      if (path === copy) return true;
      try {
        if (realpathSync(path) === copy) return true;
      } catch (error) {
        if (path.startsWith(dirname(copy))) throw Error(`No se puede comprobar una referencia de audio: ${(error as Error).message}`);
      }
    }
  }
  return false;
}
export function audioCopyToDelete(root: string, data: LibraryData, path: string): AudioDeletion | undefined {
  let metadata;
  try {
    metadata = lstatSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw Error(`No se puede comprobar el audio: ${(error as Error).message}`);
  }
  if (!metadata.isFile()) throw Error("La copia de audio no es un archivo normal");
  let canonical: string;
  try {
    canonical = realpathSync(path);
  } catch (error) {
    throw Error(`No se puede comprobar el audio: ${(error as Error).message}`);
  }
  if (!canonical.startsWith(`${audioCopyRoot(root)}/`)) throw Error("Audio fuera de la biblioteca");
  if (referencesAudio(data, canonical)) return undefined;
  return audioDeletion(canonical, metadata.dev, metadata.ino);
}
export function linkStaged(temp: string, target: string): boolean {
  try {
    linkSync(temp, target);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") {
      const matches = fileHash(temp).equals(fileHash(target));
      unlinkSync(temp);
      if (!matches) throw Error("La copia de audio existente no coincide con el origen");
      return false;
    }
    try {
      unlinkSync(temp);
    } catch (cleanup) {
      throw Error(`${(error as Error).message}; no se pudo limpiar el temporal: ${(cleanup as Error).message}`);
    }
    throw Error(`No se pudo guardar el audio: ${(error as Error).message}`);
  }
  unlinkSync(temp);
  try {
    syncDirectory(dirname(target));
  } catch (error) {
    try {
      unlinkSync(target);
    } catch (cleanup) {
      throw Error(`${(error as Error).message}; no se pudo limpiar la copia: ${(cleanup as Error).message}`);
    }
    throw Error(`No se pudo confirmar la copia de audio: ${(error as Error).message}`);
  }
  return true;
}
export const fileStem = (path: string) => basename(path).replace(/\.[^.]*$/, "");
