import { z } from "zod";
import { run as builtinConnector } from "@escriba/conectores";
import { defaultRecipeForm, type Lists } from "./defaultRecipe";
import { object, message } from "./contracts";
import type { WorkerTask } from "./contracts";
const send = globalThis.postMessage.bind(globalThis);
let sequence = 0;
const pending = new Map<
  number,
  { resolve: (value: unknown) => void; reject: (error: Error) => void }
>();
const logs: Promise<unknown>[] = [];
function rpc(operation: string, payload: unknown = {}): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    send({ type: "call", id, operation, payload });
  });
}
for (const name of [
  "fetch",
  "XMLHttpRequest",
  "WebSocket",
  "EventSource",
  "importScripts",
  "Worker",
  "SharedWorker",
  "indexedDB",
  "caches",
  "BroadcastChannel",
])
  Object.defineProperty(globalThis, name, {
    value: undefined,
    writable: false,
    configurable: false,
  });
const writeLog = (level: string, values: unknown[]) => {
  const promise = rpc("log", {
    level,
    message: values
      .map((v) => (typeof v === "string" ? v : JSON.stringify(v)))
      .join(" "),
  });
  promise.catch(() => {});
  logs.push(promise);
};
Object.defineProperty(globalThis, "console", {
  value: Object.freeze({
    log: (...v: unknown[]) => writeLog("info", v),
    info: (...v: unknown[]) => writeLog("info", v),
    warn: (...v: unknown[]) => writeLog("warn", v),
    error: (...v: unknown[]) => writeLog("error", v),
    debug: (...v: unknown[]) => writeLog("info", v),
  }),
  writable: false,
  configurable: false,
});
function load(
  source: string,
  globalName: "__recipe" | "__conectores",
): Record<string, unknown> {
  const result = new Function(
    `${source}\n;return typeof ${globalName} !== 'undefined' ? ${globalName} : undefined;`,
  )();
  return object(result);
}
function schemaJSON(schema: unknown): unknown {
  return z.toJSONSchema(schema as z.ZodType);
}
function parse(schema: unknown, value: unknown): unknown {
  const candidate = object(schema);
  if (typeof candidate.parse !== "function")
    throw Error("El esquema debe ser Zod");
  return candidate.parse(value);
}
function noteObject(
  raw: unknown,
  dataSchema?: unknown,
): Record<string, unknown> {
  let current = object(raw);
  let data: unknown = current.datos ?? null;
  const note = {
    get clave() {
      return current.clave;
    },
    get version() {
      return current.version;
    },
    get texto() {
      return current.texto;
    },
    get hablantes() {
      return current.hablantes;
    },
    get segmentos() {
      return current.segmentos;
    },
    get resumen() {
      return current.resumen;
    },
    get datos() {
      return data;
    },
    set datos(value: unknown) {
      data = value;
    },
    async resumir(options: unknown = {}) {
      current = object(
        await rpc("summarize", { ...object(options), handle: current.handle }),
      );
      return note;
    },
    async guardar(changes: unknown = {}) {
      const update = object(changes);
      if ("datos" in update) data = update.datos;
      if (dataSchema) data = parse(dataSchema, data);
      current = object(await rpc("save", { handle: current.handle, data }));
      return note;
    },
  };
  return note;
}
async function recipe(task: WorkerTask) {
  const p = task.payload;
  const lists = p.lists as Lists;
  const module = task.program ? load(task.program, "__recipe") : {};
  const form =
    typeof module.buildRecipeForm === "function"
      ? module.buildRecipeForm(lists)
      : task.program
        ? z.object({}).passthrough()
        : defaultRecipeForm(lists, p.defaultLanguage);
  if (task.kind === "recipe-schema") return schemaJSON(form);
  if (task.kind === "recipe-inspect") {
    const meta = module.receta ? object(module.receta) : {};
    if (task.program && typeof module.flujo !== "function")
      throw Error("La receta no exporta flujo");
    return {
      schema: schemaJSON(form),
      ...(typeof meta.nombre === "string" ? { name: meta.nombre } : {}),
      ...(typeof meta.descripcion === "string"
        ? { description: meta.descripcion }
        : {}),
    };
  }
  const parameters =
    task.program && typeof module.buildRecipeForm !== "function"
      ? null
      : parse(form, p.values || {});
  const metadata =
    module.receta && typeof module.receta === "object"
      ? object(module.receta)
      : {};
  const dataSchema = metadata.datos;
  const audio = Object.freeze(object(p.audio));
  const notes = new WeakMap<object, unknown>();
  const asNote = (raw: unknown) => {
    const note = noteObject(raw, dataSchema);
    notes.set(note, object(raw).handle);
    return note;
  };
  const lookup = (
    key: string,
    entries: readonly { clave: string; nombre: string }[],
  ) => {
    const found = entries.filter((e) => e.clave === key || e.nombre === key);
    if (found.length !== 1)
      throw Error(`Referencia desconocida o ambigua: ${key}`);
    return found[0];
  };
  const api = Object.freeze({
    ...lists,
    parametros: parameters,
    async transcribir(target: unknown, options: unknown = {}) {
      if (target !== audio)
        throw Error("La receta solo puede procesar su grabación");
      return asNote(await rpc("transcribe", object(options)));
    },
    async preguntar(request: unknown) {
      const args = object(request);
      const result = await rpc("ask", {
        entrada: args.entrada,
        instrucciones: args.instrucciones,
        llm: args.llm,
        ...(args.esquema ? { schema: schemaJSON(args.esquema) } : {}),
      });
      return args.esquema ? parse(args.esquema, result) : result;
    },
    conector(key: string) {
      const entry = lookup(key, lists.conectores);
      return Object.freeze({
        clave: entry.clave,
        nombre: entry.nombre,
        tipo: (entry as { tipo?: string }).tipo || null,
        async publicar(note: object) {
          if (!notes.has(note))
            throw Error("Publicar requiere una nota de esta ejecución");
          await rpc("publish", {
            destinationId: entry.clave,
            handle: notes.get(note),
          });
        },
      });
    },
    receta(key: string) {
      const entry = lookup(key, lists.recetas);
      return Object.freeze({
        clave: entry.clave,
        nombre: entry.nombre,
        tipo: (entry as { tipo?: string }).tipo || null,
        async procesar(target: unknown) {
          if (target !== audio)
            throw Error("La receta solo puede procesar su grabación");
          await rpc("process", { recipeId: entry.clave });
        },
      });
    },
    log(text: string) {
      writeLog("info", [text]);
    },
  });
  if (typeof module.flujo === "function") await module.flujo(audio, api);
  else if (task.program) throw Error("La receta no exporta flujo");
  else {
    const settings = object(parameters);
    const note = await api.transcribir(audio, {
      stt: settings.stt,
      idioma: settings.idioma,
      hablantes: settings.hablantes,
    });
    if (settings.resumir) {
      try {
        await (note.resumir as (options: unknown) => Promise<unknown>)({
          llm: settings.llm,
          prompt: settings.prompt,
        });
      } catch (error) {
        writeLog("warn", [`No se pudo resumir: ${message(error)}`]);
      }
    }
    await (note.guardar as () => Promise<unknown>)();
    for (const id of settings.conectores as string[]) {
      try {
        await api.conector(id).publicar(note);
      } catch (error) {
        writeLog("warn", [`No se pudo publicar en ${id}: ${message(error)}`]);
      }
    }
  }
  await Promise.all(logs);
  return null;
}
const attachments = new WeakMap<Blob, { start: number; end: number }>();
class Multipart {
  readonly parts: { name: string; value: string | Blob; filename?: string }[] =
    [];
  append(name: string, value: string | Blob, filename?: string) {
    this.parts.push({ name, value, filename });
  }
  *entries() {
    for (const p of this.parts) yield [p.name, p.value] as const;
  }
  get(name: string) {
    return this.parts.find((p) => p.name === name)?.value ?? null;
  }
}
function opaqueAudio(
  meta: Record<string, unknown>,
  start = 0,
  end = Number(meta.size),
): Blob {
  const blob = new Blob([], { type: String(meta.type || "audio/mp4") });
  attachments.set(blob, { start, end });
  Object.defineProperties(blob, {
    size: { value: Math.max(0, end - start) },
    slice: {
      value: (from = 0, to = end - start, type = blob.type) => {
        const size = end - start;
        const a = from < 0 ? Math.max(size + from, 0) : Math.min(from, size);
        const b = to < 0 ? Math.max(size + to, 0) : Math.min(to, size);
        return opaqueAudio(
          { ...meta, type },
          start + a,
          start + Math.max(a, b),
        );
      },
    },
    arrayBuffer: { value: () => Promise.reject(Error("El audio es opaco")) },
    text: { value: () => Promise.reject(Error("El audio es opaco")) },
    stream: {
      value: () => {
        throw Error("El audio es opaco");
      },
    },
  });
  return blob;
}
async function connector(task: WorkerTask) {
  const module = task.program ? load(task.program, "__conectores") : undefined;
  if (task.kind === "connector-inspect") {
    if (typeof module?.inspect !== "function")
      throw Error("El programa no exporta inspect");
    return module.inspect();
  }
  Object.defineProperty(globalThis, "FormData", { value: Multipart });
  const host = {
    async fetch(input: RequestInfo | URL, init?: RequestInit) {
      const suppliedHeaders = new Headers(init?.headers);
      suppliedHeaders.delete("user-agent");
      const headers = Object.fromEntries(suppliedHeaders.entries());
      const body = init?.body;
      let multipart: unknown[] | undefined;
      if (body instanceof Multipart)
        multipart = body.parts.map((p) => {
          if (typeof p.value === "string")
            return { name: p.name, value: p.value };
          const audio = attachments.get(p.value);
          if (!audio) throw Error("El adjunto no pertenece a la grabación");
          return {
            name: p.name,
            audio,
            filename: p.filename,
            type: p.value.type,
          };
        });
      else if (body !== undefined && body !== null && typeof body !== "string")
        throw Error("El cuerpo HTTP no es compatible");
      const result = object(
        await rpc("connector.http", {
          url: String(input),
          method: init?.method || "GET",
          headers,
          ...(multipart ? { multipart } : { body }),
        }),
      );
      return new Response(
        [204, 205, 304].includes(Number(result.status))
          ? null
          : String(result.body || ""),
        {
          status: Number(result.status),
          headers: result.headers as Record<string, string>,
        },
      );
    },
    files: {
      snapshot: async () =>
        (await rpc("connector.snapshot")) as Record<string, string>,
      apply: async (changes: unknown) => {
        await rpc("connector.apply", { changes });
      },
    },
    audio: async () => {
      const result = await rpc("connector.audio");
      if (!result) return null;
      const meta = object(result);
      return { data: opaqueAudio(meta), filename: String(meta.filename) };
    },
    checkpoint: async (receipt: unknown) => {
      await rpc("connector.checkpoint", { receipt });
    },
  };
  const fn = module?.run || builtinConnector;
  if (typeof fn !== "function") throw Error("El programa no exporta run");
  return fn(task.payload, host);
}
globalThis.onmessage = (event) => {
  const data = object(event.data);
  if (data.type === "resolve" || data.type === "reject") {
    const waiter = pending.get(Number(data.id));
    if (!waiter) return;
    pending.delete(Number(data.id));
    if (data.type === "resolve") waiter.resolve(data.value);
    else waiter.reject(Error(String(data.message)));
    return;
  }
  if (data.type === "start") {
    const task = data.task as WorkerTask;
    Promise.resolve()
      .then(() =>
        task.kind.startsWith("recipe") ? recipe(task) : connector(task),
      )
      .then(
        (value) => send({ type: "result", value }),
        (error) => send({ type: "error", message: message(error) }),
      );
  }
};
