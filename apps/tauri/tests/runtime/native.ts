import { fileURLToPath } from "node:url";

export function surrealNativeLibrary(): string {
  const arch = process.arch === "arm64" ? "arm64" : "x64";
  return fileURLToPath(new URL(`../../node_modules/@surrealdb/node-native-darwin-${arch}/surrealdb-node.darwin-${arch}.node`, import.meta.url));
}
export const controllerEnvironment = (data: string) => ({ ESCRIBA_DATA: data, NAPI_RS_NATIVE_LIBRARY_PATH: surrealNativeLibrary() });
