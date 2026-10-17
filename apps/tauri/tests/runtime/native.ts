import { fileURLToPath } from "node:url";
import { surrealNative } from "../../runtime-host/targets.mjs";

export function surrealNativeLibrary(): string {
  const native = surrealNative(process.platform, process.arch);
  return fileURLToPath(new URL(`../../node_modules/${native.package}/${native.file}`, import.meta.url));
}
export const controllerEnvironment = (data: string) => ({ ...(process.platform === "win32" ? { SystemRoot: process.env.SystemRoot, TEMP: process.env.TEMP, LOCALAPPDATA: process.env.LOCALAPPDATA } : {}), ESCRIBA_DATA: data, NAPI_RS_NATIVE_LIBRARY_PATH: surrealNativeLibrary() });
