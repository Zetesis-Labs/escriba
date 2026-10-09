import { build } from "esbuild";
import {
  mkdir,
  readdir,
  readFile,
  writeFile,
  copyFile,
} from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const root = dirname(fileURLToPath(import.meta.url));
const resources = join(root, "../../Sources/EscribaJSC/Resources/conectores");
await mkdir(resources, { recursive: true });
await build({
  entryPoints: [join(root, "src/index.ts")],
  bundle: true,
  platform: "browser",
  format: "iife",
  globalName: "__conectores",
  outfile: join(root, "dist/conectores.js"),
});
await copyFile(
  join(root, "dist/conectores.js"),
  join(resources, "conectores.js"),
);
await build({
  entryPoints: [join(root, "src/index.ts")],
  bundle: true,
  platform: "browser",
  format: "esm",
  outfile: join(resources, "index.js"),
});
for (const name of ["index", "types", "notion", "okf"]) {
  const declaration = await readFile(
    join(root, "dist", name + ".d.ts"),
    "utf8",
  );
  await writeFile(
    join(resources, name + ".d.ts"),
    declaration.replace('from "zod"', 'from "./vendor/zod/index.js"'),
  );
}
async function declarations(source, target) {
  await mkdir(target, { recursive: true });
  for (const entry of await readdir(source, { withFileTypes: true })) {
    const from = join(source, entry.name),
      to = join(target, entry.name);
    if (entry.isDirectory()) await declarations(from, to);
    else if (entry.name.endsWith(".d.ts")) {
      const text = await readFile(from, "utf8");
      await writeFile(to, text.replace(/[ \t]+$/gm, ""));
    }
  }
}
await declarations(
  join(root, "node_modules/zod"),
  join(resources, "vendor/zod"),
);
await copyFile(
  join(root, "node_modules/zod/LICENSE"),
  join(resources, "vendor/zod/LICENSE"),
);
await mkdir(join(resources, "licenses"), { recursive: true });
for (const [name, location] of [
  ["notion", "@notionhq/client"],
  ["noble-hashes", "@noble/hashes"],
  ["zod", "zod"],
])
  await copyFile(
    join(root, "node_modules", location, "LICENSE"),
    join(resources, "licenses", name + ".txt"),
  );
await copyFile(join(root, "../../LICENSE"), join(resources, "LICENSE"));
await writeFile(
  join(resources, "package.json"),
  JSON.stringify(
    {
      name: "@escriba/conectores",
      version: "0.1.0",
      type: "module",
      exports: { ".": { types: "./index.d.ts", import: "./index.js" } },
      types: "./index.d.ts",
      files: [
        "index.js",
        "index.d.ts",
        "types.d.ts",
        "notion.d.ts",
        "okf.d.ts",
        "conectores.js",
        "vendor",
        "licenses",
        "LICENSE",
      ],
      license: "MIT",
    },
    null,
    2,
  ) + "\n",
);
