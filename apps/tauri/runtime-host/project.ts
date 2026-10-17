import { randomUUID } from "node:crypto";
import { isBuiltin } from "node:module";
import { lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve, sep } from "node:path";

type BuildResult = {
  success: boolean;
  logs: unknown[];
  outputs: Array<{ kind: string; path: string; text(): Promise<string> }>;
  metafile?: {
    inputs: Record<string, { imports: Array<{ path: string; external?: boolean }> }>;
    outputs: Record<string, { imports: Array<{ path: string }> }>;
  };
};

declare const Bun: {
  build(options: {
    entrypoints: string[];
    files: Record<string, string>;
    root: string;
    target: "bun";
    format: "cjs";
    packages: "bundle";
    splitting: false;
    env: "disable";
    metafile: true;
    plugins: Array<{
      name: string;
      setup(build: {
        onResolve(
          options: { filter: RegExp },
          resolve: (args: { path: string; importer: string }) => { path: string } | undefined,
        ): void;
      }): void;
    }>;
  }): Promise<BuildResult>;
  resolveSync(specifier: string, importer: string): string;
};

type Recipe = { id: string; name: string; entry: string; file: string };
type Source = { entry: string; directory: string };
const EXCLUDED = new Set(["dist", "node_modules", ".git", ".escriba"]);
const MAX_RECIPES = 10_000;
const MAX_BUNDLE = 32 * 1024 * 1024;
const MAX_CATALOG = 30 * 1024 * 1024;

function filesystemPath(path: string) {
  if (process.platform !== "win32") return path;
  if (path.startsWith("\\\\?\\UNC\\")) return `\\\\${path.slice(8)}`;
  return /^\\\\\?\\[a-z]:\\/i.test(path) ? path.slice(4) : path;
}

async function canonicalPath(path: string) {
  return filesystemPath(await realpath(filesystemPath(path)));
}

function within(path: string, directory: string) {
  return path === directory || path.startsWith(`${directory}${sep}`);
}

async function sources(root: string): Promise<Source[]> {
  const found = new Map<string, Source>();
  async function visit(directory: string): Promise<void> {
    for (const item of await readdir(directory, { withFileTypes: true })) {
      if (EXCLUDED.has(item.name)) continue;
      const path = join(directory, item.name);
      if (item.isDirectory()) {
        await visit(path);
      } else if (item.isFile() && (item.name === "receta.ts" || item.name === "receta.js")) {
        const parent = relative(root, directory).split(sep).join("/");
        if (!parent) continue;
        const entry = relative(root, path).split(sep).join("/");
        const old = found.get(parent);
        if (!old || item.name === "receta.ts") found.set(parent, { entry, directory: parent });
      }
    }
  }
  await visit(root);
  if (found.size > MAX_RECIPES) throw Error("El proyecto supera 10000 recetas");
  return [...found.values()].sort((a, b) => a.directory.localeCompare(b.directory));
}

function identity(directory: string) {
  const normalized = directory.startsWith("src/") ? directory.slice(4) : directory;
  const direct = normalized.match(/^recetas\/([^/]+)$/);
  return direct ? direct[1] : `code:${normalized.replaceAll("/", ":")}`;
}

async function sourcePath(root: string, relativePath: string) {
  const path = resolve(root, relativePath);
  if (!within(path, root)) throw Error("Fuente fuera del proyecto");
  const real = await canonicalPath(path);
  if (!within(real, root)) throw Error("Fuente enlazada fuera del proyecto");
  return path;
}

async function moduleEntry(root: string, filename: string) {
  for (const name of [`src/${filename}.ts`, `${filename}.ts`]) {
    const path = join(root, name);
    try {
      const metadata = await lstat(path);
      if (!metadata.isFile()) throw Error(`Módulo inválido: ${name}`);
      return name;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return undefined;
}

async function permittedVendor(vendor: string) {
  const modules = (await lstat(join(vendor, "node_modules")).catch(() => undefined))?.isDirectory()
    ? join(vendor, "node_modules") : vendor;
  const real = await canonicalPath(modules);
  const allowed = [real];
  for (const packageName of ["zod", "@escriba/conectores", "surrealdb"]) {
    try { allowed.push(await canonicalPath(join(real, packageName))); }
    catch { throw Error(`No está disponible ${packageName} en las dependencias incluidas`); }
  }
  return { modules: real, allowed };
}

function vendorFallback(modules: string) {
  return {
    name: "escriba-dependencias-incluidas",
    setup(build: {
      onResolve(
        options: { filter: RegExp },
        resolve: (args: { path: string; importer: string }) => { path: string } | undefined,
      ): void;
    }) {
      build.onResolve({ filter: /^(zod|@escriba\/conectores|surrealdb)(\/.*)?$/ }, (args) => {
        try {
          Bun.resolveSync(args.path, args.importer);
          return undefined;
        } catch {
          return { path: Bun.resolveSync(args.path, join(modules, "..", "__escriba_vendor__.ts")) };
        }
      });
    },
  };
}

function buildProblem(error: unknown): string {
  if (error instanceof AggregateError)
    return error.errors.map(buildProblem).join("; ");
  return String(error);
}

async function bundle(
  root: string, vendor: { modules: string; allowed: string[] },
  entry: string, globalName: "__recipe" | "__conectores" | "__ontologias",
): Promise<string> {
  const source = await sourcePath(root, entry);
  const wrapper = join(root, ".escriba", `entry-${randomUUID()}.ts`);
  const result = await Bun.build({
    entrypoints: [wrapper],
    files: { [wrapper]: `import * as module from ${JSON.stringify(source)}; globalThis.${globalName} = module;` },
    root, target: "bun", format: "cjs", packages: "bundle", splitting: false,
    env: "disable", metafile: true, plugins: [vendorFallback(vendor.modules)],
  }).catch((error: unknown) => {
    throw Error(`No se pudo compilar ${entry}: ${buildProblem(error)}`);
  });
  if (!result.success) throw Error(`No se pudo compilar ${entry}: ${result.logs.map(String).join("; ")}`);
  if (!result.metafile || result.outputs.length !== 1 || result.outputs[0].kind !== "entry-point")
    throw Error(`La compilación de ${entry} produjo archivos auxiliares`);
  const outputInfo = Object.values(result.metafile.outputs);
  if (outputInfo.length !== 1 || outputInfo[0].imports.length)
    throw Error(`El paquete ${entry} conserva importaciones externas`);
  for (const [input, info] of Object.entries(result.metafile.inputs)) {
    if (info.imports.some((item) => item.external && !isBuiltin(item.path)))
      throw Error(`El paquete ${entry} importa una dependencia externa`);
    if (isBuiltin(input)) continue;
    const path = resolve(input);
    if (path === wrapper) continue;
    const real = await canonicalPath(path);
    if (!within(real, root) && !vendor.allowed.some((directory) => within(real, directory)))
      throw Error(`El paquete ${entry} importa una fuente fuera del proyecto`);
  }
  const native = await result.outputs[0].text();
  const program = `const __escribaModule = { exports: {} };\nconst __escribaEntry = ${native};\n__escribaEntry(__escribaModule.exports, require, __escribaModule, "", "");\n`;
  if (!program || Buffer.byteLength(program) > MAX_BUNDLE)
    throw Error(`El paquete ${entry} está vacío o supera 32 MiB`);
  return program;
}

async function inspectOldDist(path: string) {
  let metadata;
  try { metadata = await lstat(path); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
  if (!metadata.isDirectory() || metadata.isSymbolicLink())
    throw Error("dist debe ser una carpeta propia, no un enlace");
  let manifest: unknown;
  try { manifest = JSON.parse(await readFile(join(path, "escriba.json"), "utf8")); }
  catch { throw Error("dist ya existe y no contiene un manifiesto de Escriba"); }
  if (!manifest || typeof manifest !== "object") throw Error("Manifiesto anterior inválido");
  const value = manifest as { version?: unknown; recipes?: unknown; connectors?: unknown; ontologies?: unknown };
  if (value.version !== 1 || !Array.isArray(value.recipes)) throw Error("Manifiesto anterior inválido");
  const names = new Set(["escriba.json"]);
  function addFile(file: unknown) {
    if (typeof file !== "string" || !file.endsWith(".js") || file.includes("\\")
      || file.includes("\0") || file.split("/").some((part) => !part || part === "." || part === ".."))
      throw Error("Manifiesto anterior contiene rutas desconocidas");
    if (names.has(file)) throw Error("Manifiesto anterior repite archivos");
    names.add(file);
  }
  for (const recipe of value.recipes) {
    addFile((recipe as { file?: unknown })?.file);
  }
  if (value.connectors !== undefined) addFile(value.connectors);
  if (value.ontologies !== undefined) addFile(value.ontologies);
  const ancestors = new Set<string>();
  for (const name of names) {
    const parts = name.split("/");
    for (let index = 1; index < parts.length; index++)
      ancestors.add(parts.slice(0, index).join("/"));
  }
  const seen = new Set<string>();
  async function inspect(directory: string, prefix = ""): Promise<void> {
    for (const item of await readdir(directory, { withFileTypes: true })) {
      const name = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.isDirectory() && ancestors.has(name)) await inspect(join(directory, item.name), name);
      else if (item.isFile() && names.has(name)) seen.add(name);
      else throw Error("dist contiene archivos ajenos; no se reemplazará");
    }
  }
  await inspect(path);
  if (seen.size !== names.size)
    throw Error("dist contiene archivos ajenos; no se reemplazará");
  return true;
}

export async function buildProject(rootPath: string, vendorPath: string): Promise<void> {
  if (!isAbsolute(rootPath) || !isAbsolute(vendorPath))
    throw Error("Las rutas del proyecto y vendor deben ser absolutas");
  const root = await canonicalPath(rootPath);
  const vendor = await permittedVendor(filesystemPath(vendorPath));
  const entries = await sources(root);
  const connector = await moduleEntry(root, "conectores");
  const ontology = await moduleEntry(root, "ontologias");
  const dist = join(root, "dist");
  const hadDist = await inspectOldDist(dist);
  const managed = join(root, ".escriba");
  try {
    const metadata = await lstat(managed);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw Error(".escriba debe ser una carpeta real");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") await mkdir(managed);
    else throw error;
  }
  const stage = await mkdtemp(join(managed, "build-"));
  const backup = join(managed, `previous-${randomUUID()}`);
  let movedOld = false;
  let failure: unknown;
  try {
    const recipes: Recipe[] = [];
    const ids = new Set<string>();
    let totalBytes = 0;
    for (const [index, source] of entries.entries()) {
      const id = identity(source.directory);
      if (ids.has(id)) throw Error(`ID de receta repetido: ${id}`);
      ids.add(id);
      const file = `receta-${index}.js`;
      const program = await bundle(root, vendor, source.entry, "__recipe");
      totalBytes += Buffer.byteLength(JSON.stringify({ id, name: basename(source.directory), entry: source.entry, bundle: program }));
      if (totalBytes > MAX_CATALOG) throw Error("Los paquetes superan el límite total de 30 MiB");
      await writeFile(join(stage, file), program);
      recipes.push({ id, name: basename(source.directory), entry: source.entry, file });
    }
    if (connector) {
      const program = await bundle(root, vendor, connector, "__conectores");
      totalBytes += Buffer.byteLength(JSON.stringify(program));
      if (totalBytes > MAX_CATALOG) throw Error("Los paquetes superan el límite total de 30 MiB");
      await writeFile(join(stage, "conectores.js"), program);
    }
    if (ontology) {
      const program = await bundle(root, vendor, ontology, "__ontologias");
      totalBytes += Buffer.byteLength(JSON.stringify(program));
      if (totalBytes > MAX_CATALOG) throw Error("Los paquetes superan el límite total de 30 MiB");
      await writeFile(join(stage, "ontologias.js"), program);
    }
    await writeFile(join(stage, "escriba.json"), JSON.stringify({
      version: 1, recipes, ...(connector ? { connectors: "conectores.js" } : {}),
      ...(ontology ? { ontologies: "ontologias.js" } : {}),
    }));
    if (hadDist) {
      await rename(dist, backup);
      movedOld = true;
    }
    try { await rename(stage, dist); }
    catch (error) {
      if (movedOld) {
        try { await rename(backup, dist); }
        catch (restore) { throw new AggregateError([error, restore], "No se pudo promover ni restaurar dist"); }
      }
      movedOld = false;
      throw error;
    }
    if (movedOld) {
      try { await rm(backup, { recursive: true }); }
      catch (error) { process.stderr.write(`No se pudo limpiar el dist anterior: ${String(error)}\n`); }
    }
    process.stdout.write(`${JSON.stringify({ recipes: recipes.length, connectors: Boolean(connector) })}\n`);
  } catch (error) {
    failure = error;
    throw error;
  } finally {
    try { await rm(stage, { recursive: true, force: true }); }
    catch (error) {
      if (failure) process.stderr.write(`No se pudo limpiar staging: ${String(error)}\n`);
      else throw error;
    }
  }
}
