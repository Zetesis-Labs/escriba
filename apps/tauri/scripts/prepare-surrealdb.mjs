import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join, resolve } from "node:path";
import { build } from "esbuild";

export async function prepareSurrealdb(app, vendor) {
  const source = join(app, "node_modules/surrealdb");
  const target = join(vendor, "surrealdb");
  const manifest = JSON.parse(await readFile(join(source, "package.json"), "utf8"));
  const bundled = await build({
    entryPoints: [join(source, "dist/surrealdb.mjs")],
    bundle: true,
    platform: "browser",
    format: "esm",
    target: "es2022",
    write: false,
    legalComments: "none",
  });
  if (bundled.outputFiles.length !== 1) throw Error("No se pudo incluir el SDK SurrealDB");
  const declaration = await readFile(join(source, "dist/surrealdb.d.ts"), "utf8");
  const cborTypes = await readFile(join(app, "node_modules/@surrealdb/cbor/dist/index.d.ts"), "utf8");
  const uuidTypes = await readFile(join(app, "node_modules/uuidv7/dist/index.d.ts"), "utf8");
  const replacer = cborTypes.match(/^export type Replacer = .*;$/m)?.[0].replace("export ", "");
  const uuidStart = uuidTypes.indexOf("export declare class UUID {");
  const uuidEnd = uuidTypes.indexOf("\n}\n", uuidStart);
  if (!replacer || uuidStart < 0 || uuidEnd < 0) throw Error("Las dependencias de tipos del SDK SurrealDB cambiaron");
  const uuid = uuidTypes.slice(uuidStart, uuidEnd + 2).replace("export declare class UUID", "declare class UUID");
  const standaloneTypes = declaration
    .replace("import { Replacer } from '@surrealdb/cbor';", replacer)
    .replace("import { UUID } from 'uuidv7';", uuid);
  if (standaloneTypes === declaration || standaloneTypes.includes("from '@surrealdb/cbor'")
    || standaloneTypes.includes("from 'uuidv7'"))
    throw Error("Las declaraciones del SDK SurrealDB cambiaron");
  await rm(target, { recursive: true, force: true });
  await mkdir(join(target, "licenses"), { recursive: true });
  await writeFile(join(target, "index.js"), bundled.outputFiles[0].contents);
  await writeFile(join(target, "index.d.ts"), standaloneTypes);
  await writeFile(join(target, "package.json"), JSON.stringify({
    name: "surrealdb",
    version: manifest.version,
    type: "module",
    main: "./index.js",
    types: "./index.d.ts",
    exports: { ".": { types: "./index.d.ts", import: "./index.js", default: "./index.js" } },
  }));
  for (const [name, license] of [
    ["surrealdb", join(source, "LICENSE")],
    ["sqon", join(app, "node_modules/@surrealdb/sqon/LICENSE")],
    ["cbor", join(app, "node_modules/@surrealdb/sqon/LICENSE")],
    ["uuidv7", join(app, "node_modules/uuidv7/LICENSE")],
  ]) await cp(license, join(target, "licenses", `${name}.txt`));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const app = fileURLToPath(new URL("..", import.meta.url));
  await prepareSurrealdb(app, join(app, "src-tauri/vendor/node_modules"));
}
