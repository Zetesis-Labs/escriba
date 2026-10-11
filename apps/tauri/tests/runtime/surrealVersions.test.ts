import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { EMULATED_SURREAL_VERSION } from "../../src/runtime/knowledge";

const paired = { sdk: "2.1.1", server: "3.3.2" };
const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

test("el SDK de las recetas, el servidor que emula el grafo y SurrealDB de Rust cambian juntos", () => {
  const manifest = JSON.parse(read("../../package.json")) as { dependencies: Record<string, string> };
  const installed = JSON.parse(read("../../node_modules/surrealdb/package.json")) as { version: string };
  const rust = [...read("../../src-tauri/Cargo.toml").matchAll(/^surrealdb(?:-core|-expr)? = \{ version = "=([^"]+)"/gm)].map((match) => match[1]);
  expect({ declared: manifest.dependencies.surrealdb, installed: installed.version, emulated: EMULATED_SURREAL_VERSION, rust }).toEqual({
    declared: paired.sdk,
    installed: paired.sdk,
    emulated: paired.server,
    rust: [paired.server, paired.server, paired.server],
  });
});
