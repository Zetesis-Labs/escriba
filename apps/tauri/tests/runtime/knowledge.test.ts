import { beforeAll, test } from "vitest";
import assert from "node:assert/strict";
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { CborCodec, DateTime, Decimal, RecordId } from "surrealdb";
import { createWorkerRunner, type WorkerPort } from "../../src/runtime/workerClient";

const root = fileURLToPath(new URL("../../../../", import.meta.url));
let workerCode = "";
beforeAll(async () => {
  const built = await build({
    entryPoints: [`${root}apps/tauri/src/runtime/worker.ts`],
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    alias: { "@escriba/conectores": `${root}packages/conectores/src/index.ts` },
    nodePaths: [`${root}apps/tauri/node_modules`],
  });
  workerCode = built.outputFiles[0].text;
});
function runner() {
  return createWorkerRunner(() => {
    const worker = new Worker(
      `const {parentPort}=require('node:worker_threads');globalThis.postMessage=(data)=>parentPort.postMessage(data);parentPort.on('message',data=>globalThis.onmessage({data}));${workerCode}`,
      { eval: true },
    );
    const port: WorkerPort = {
      postMessage: (value) => worker.postMessage(value),
      terminate: () => { void worker.terminate(); },
      onmessage: null,
      onerror: null,
      onmessageerror: null,
    };
    worker.on("message", (data) => port.onmessage?.({ data } as MessageEvent));
    worker.on("error", (error) => port.onerror?.({ message: error.message } as ErrorEvent));
    return port;
  });
}
async function program(source: string, globalName = "__recipe") {
  const built = await build({
    stdin: { contents: source, resolveDir: `${root}apps/tauri` },
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    globalName,
    nodePaths: [`${root}apps/tauri/node_modules`],
  });
  return built.outputFiles[0].text;
}
const lists = { stts: [], llms: [], conectores: [], recetas: [], cuentas: [] };
const payload = { audio: { clave: "r", nombre: "Nota" }, lists, values: {} };

test("una receta usa el SDK oficial para consultas y relaciones con valores Surreal tipados", async () => {
  const recipe = await program(`import { RecordId, Decimal, DateTime, Table } from 'surrealdb';
    export const ontologias = [{ id: 'personas', minVersion: 2, maxVersion: 3 }];
    export async function flujo(_audio, api) {
      const db = await api.grafo('personas');
      const from = new RecordId('persona', 'ada');
      const to = new RecordId('persona', 'grace');
      const rows = await db.query('SELECT * FROM persona WHERE id = $id AND tarifa = $tarifa AND fecha = $fecha', {
        id: from, tarifa: new Decimal('12.34'), fecha: new DateTime('2024-01-02T03:04:05Z')
      });
      if (!(rows[0][0].id instanceof RecordId) || !(rows[0][0].tarifa instanceof Decimal)
          || !(rows[0][0].fecha instanceof DateTime)) throw Error('tipos perdidos');
      const selected = await db.select(from);
      const selectedRecord = Array.isArray(selected) ? selected[0] : selected;
      if (!(selectedRecord.id instanceof RecordId)) throw Error('select perdió RecordId');
      await db.relate(from, new Table('conoce'), to, { desde: new DateTime('2024-01-02T03:04:05Z') });
    }`);
  const calls: { operation: string; payload: Record<string, unknown> }[] = [];
  await runner().run({ kind: "recipe", program: recipe, payload }, {
    call: async (operation, raw) => {
      const args = raw as Record<string, unknown>;
      calls.push({ operation, payload: args });
      if (operation === "graph.open") return { version: 3 };
      if (operation === "graph.query") {
        const sql = String(args.sql);
        const bindings = CborCodec.DEFAULT.decode<Record<string, unknown>>(Buffer.from(String(args.bindings), "base64"));
        if (sql.includes("tarifa")) {
          assert.ok(bindings.id instanceof RecordId);
          assert.ok(bindings.tarifa instanceof Decimal);
          assert.ok(bindings.fecha instanceof DateTime);
          return Buffer.from(CborCodec.DEFAULT.encode([[{
            id: bindings.id, tarifa: bindings.tarifa, fecha: bindings.fecha,
          }]])).toString("base64");
        }
        if (sql.startsWith("SELECT")) {
          assert.ok(Object.values(bindings).some((value) => value instanceof RecordId));
          return Buffer.from(CborCodec.DEFAULT.encode([[{ id: new RecordId("persona", "ada") }]])).toString("base64");
        }
        assert.match(sql, /^RELATE /);
        return Buffer.from(CborCodec.DEFAULT.encode([[{ id: new RecordId("conoce", "a") }]])).toString("base64");
      }
      throw Error(`Capacidad inesperada: ${operation}`);
    },
  });
  assert.deepEqual(calls.map((call) => call.operation), ["graph.open", "graph.query", "graph.query", "graph.query"]);
  assert.equal(calls[1].payload.ontologyId, "personas");
  assert.equal(calls[1].payload.expectedVersion, 3);
  assert.equal(calls[2].payload.expectedVersion, 3);
  assert.equal(calls[3].payload.expectedVersion, 3);
});

test("inspección de receta y ontología devuelve sus declaraciones sin capacidades", async () => {
  const recipe = await program("export const ontologias = [{ id: 'personas', minVersion: 2, maxVersion: 3 }]; export async function flujo() {}");
  const inspected = await runner().run({ kind: "recipe-inspect", program: recipe, payload: { lists } }, {
    call: async () => { throw Error("inspección no usa capacidades"); },
  }) as { ontologias: unknown };
  assert.deepEqual(inspected.ontologias, [{ id: "personas", minVersion: 2, maxVersion: 3 }]);
  const ontology = await program("export const ontologias = [{ id: 'personas', version: 3, schema: 'DEFINE TABLE persona' }];", "__ontologias");
  assert.deepEqual(await runner().run({ kind: "ontology-inspect", program: ontology, payload: {} }, {
    call: async () => { throw Error("inspección no usa capacidades"); },
  }), { ontologies: [{ id: "personas", version: 3, schema: "DEFINE TABLE persona" }] });
});

test("una nota confirmada se vincula al grafo por su versión activa", async () => {
  const recipe = await program(`export const ontologias = [{ id: 'personas', minVersion: 2, maxVersion: 2 }];
    export async function flujo(audio, api) {
      const note = await api.transcribir(audio);
      await note.guardar();
      await note.vincular('personas', 'persona:ada');
    }`);
  const calls: { operation: string; payload: Record<string, unknown> }[] = [];
  await runner().run({ kind: "recipe", program: recipe, payload }, {
    call: async (operation, raw) => {
      const args = raw as Record<string, unknown>;
      calls.push({ operation, payload: args });
      if (operation === "transcribe" || operation === "save")
        return { handle: "version-123", clave: "recording-1", version: 1, texto: "Texto", segmentos: [], datos: null };
      if (operation === "graph.open") return { version: 2 };
      if (operation === "graph.link") return null;
      throw Error(`Capacidad inesperada: ${operation}`);
    },
  });
  assert.deepEqual(calls.map((call) => call.operation), ["transcribe", "save", "graph.open", "graph.link"]);
  assert.deepEqual(calls[3].payload, { noteId: "version-123", ontologyId: "personas", recordId: "persona:ada", expectedVersion: 2 });
});

test("la nota rechaza un vínculo manual a la base derivada antes de abrir el grafo", async () => {
  const recipe = await program(`export async function flujo(audio, api) {
    const note = await api.transcribir(audio);
    await note.guardar();
    let denied = false;
    try { await note.vincular('escriba', 'segment:sample'); } catch (error) { denied = String(error).includes('base de Escriba'); }
    if (!denied) throw Error('Se permitió vincular la base derivada');
  }`);
  const calls: string[] = [];
  await runner().run({ kind: "recipe", program: recipe, payload }, {
    call: async (operation) => {
      calls.push(operation);
      if (operation === "transcribe" || operation === "save")
        return { handle: "version-123", clave: "recording-1", version: 1, texto: "Texto", segmentos: [], datos: null };
      throw Error(`Capacidad inesperada: ${operation}`);
    },
  });
  assert.deepEqual(calls, ["transcribe", "save"]);
});

test("el SDK del grafo impide sesiones ajenas y operaciones que requieren un canal persistente", async () => {
  const recipe = await program(`import { Table } from 'surrealdb';
    export async function flujo(_audio, api) {
      const db = await api.grafo('personas');
      for (const operation of [
        () => db.use({ namespace: 'escriba', database: 'library' }),
        () => db.signin({ username: 'root', password: 'secret' }),
        () => db.beginTransaction(),
        () => db.live(new Table('persona')),
      ]) {
        let denied = false;
        try { await operation(); } catch { denied = true; }
        if (!denied) throw Error('operación indebidamente disponible');
      }
    }`);
  const calls: string[] = [];
  await runner().run({ kind: "recipe", program: recipe, payload }, {
    call: async (operation) => {
      calls.push(operation);
      if (operation === "graph.open") return { version: 1 };
      throw Error(`Capacidad inesperada: ${operation}`);
    },
  });
  assert.deepEqual(calls, ["graph.open"]);
});
