import { expect, test } from "vitest";
import { bunTarget, hostTriple, surrealNative, typescriptPackage } from "../../runtime-host/targets.mjs";

test("el triple del equipo cubre macOS y Linux en las dos arquitecturas", () => {
  expect(hostTriple("darwin", "arm64")).toBe("aarch64-apple-darwin");
  expect(hostTriple("darwin", "x64")).toBe("x86_64-apple-darwin");
  expect(hostTriple("linux", "arm64")).toBe("aarch64-unknown-linux-gnu");
  expect(hostTriple("linux", "x64")).toBe("x86_64-unknown-linux-gnu");
  expect(hostTriple("win32", "x64")).toBe("x86_64-pc-windows-msvc");
  expect(() => hostTriple("win32", "ia32")).toThrow("win32");
});

test("el comprobador TypeScript incluido es el paquete nativo de cada sistema", () => {
  expect(typescriptPackage("darwin", "arm64")).toBe("@typescript/typescript-darwin-arm64");
  expect(typescriptPackage("linux", "x64")).toBe("@typescript/typescript-linux-x64");
  expect(typescriptPackage("linux", "arm64")).toBe("@typescript/typescript-linux-arm64");
  expect(typescriptPackage("win32", "x64")).toBe("@typescript/typescript-win32-x64");
});

test("Bun compila el runtime para cada triple soportado", () => {
  expect(bunTarget("aarch64-apple-darwin")).toBe("bun-darwin-arm64");
  expect(bunTarget("x86_64-apple-darwin")).toBe("bun-darwin-x64");
  expect(bunTarget("aarch64-unknown-linux-gnu")).toBe("bun-linux-arm64");
  expect(bunTarget("x86_64-unknown-linux-gnu")).toBe("bun-linux-x64");
  expect(bunTarget("x86_64-pc-windows-msvc")).toBe("bun-windows-x64");
});

test("el binding de SurrealDB del controlador es el de cada sistema", () => {
  expect(surrealNative("darwin", "arm64")).toEqual({
    package: "@surrealdb/node-native-darwin-arm64",
    file: "surrealdb-node.darwin-arm64.node",
  });
  expect(surrealNative("linux", "x64")).toEqual({
    package: "@surrealdb/node-native-linux-x64-gnu",
    file: "surrealdb-node.linux-x64-gnu.node",
  });
  expect(surrealNative("linux", "arm64").file).toBe("surrealdb-node.linux-arm64-gnu.node");
  expect(surrealNative("win32", "x64")).toEqual({
    package: "@surrealdb/node-native-win32-x64-msvc",
    file: "surrealdb-node.win32-x64-msvc.node",
  });
});
