import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { type ConnectionState, Surreal } from "surrealdb";
import type { Json } from "./json";

export type Database = Surreal;
export const ALREADY_OPEN = "Escriba ya está abierta con esta biblioteca";
const openPaths = new Set<string>();

class FilesystemEndpoint extends URL {
  constructor(private readonly path: string) {
    super("rocksdb://");
  }
  override toString() {
    return `rocksdb://${this.path}`;
  }
}

export async function closeDatabase(db: Surreal, path: string) {
  openPaths.delete(path);
  await db.close();
}
export async function openDatabase(path: string, namespace: string, database: string): Promise<Surreal> {
  if (path.includes("?")) throw Error("La ruta de la biblioteca contiene '?' y el motor no puede abrirla de forma segura");
  const legacy = `${path.replace(/\.[^./]+$/, "")}.surrealkv`;
  if (existsSync(legacy)) throw Error(`${legacy} está en SurrealKV y esta versión ya no lo convierte`);
  if (openPaths.has(path)) throw Error(ALREADY_OPEN);
  mkdirSync(path, { recursive: true });
  chmodSync(path, 0o700);
  const { NodeEngine } = await import("@surrealdb/node");
  class RocksDbEngine extends NodeEngine {
    override open(state: ConnectionState) {
      // El motor nativo recibe una ruta física; la serialización URL del SDK la escaparía.
      super.open({ ...state, url: new FilesystemEndpoint(path) });
    }
  }
  for (let attempt = 0; ; attempt++) {
    const db = new Surreal({
      engines: {
        rocksdb: (context) => new RocksDbEngine(context, {
          defaults: false,
          capabilities: { scripting: false, guest_access: false, live_query_notifications: false, network_targets: false, experimental: false },
        }),
      },
    });
    try {
      await db.connect("rocksdb://", { namespace, database });
      openPaths.add(path);
      return db;
    } catch (error) {
      await db.close().catch(() => undefined);
      const message = String((error as Error)?.message ?? error).toLowerCase();
      const locked = message.includes("lock") || message.includes("unexpected connection error");
      if (locked && attempt < 20) {
        await new Promise((resolve) => setTimeout(resolve, 50));
        continue;
      }
      throw Error(locked ? ALREADY_OPEN : `No se pudo abrir ${path}: ${(error as Error)?.message ?? error}`);
    }
  }
}
export async function run<T extends unknown[] = unknown[]>(db: Surreal, sql: string, vars?: Record<string, unknown>): Promise<T> {
  try {
    return (await db.query<T>(sql, vars)) as T;
  } catch (error) {
    throw Error(String((error as Error)?.message ?? error));
  }
}
export class Transaction {
  private readonly statements: string[] = [];
  readonly vars: Record<string, unknown> = {};
  private counter = 0;
  bind(value: unknown): string {
    const name = `p${this.counter++}`;
    this.vars[name] = value;
    return `$${name}`;
  }
  add(statement: string) {
    this.statements.push(statement);
  }
  get empty() {
    return this.statements.length === 0;
  }
  async commit(db: Surreal) {
    if (this.empty) return;
    await run(db, `BEGIN TRANSACTION; ${this.statements.join("; ")}; COMMIT TRANSACTION;`, this.vars);
  }
}
export const literal = (value: string) => JSON.stringify(value);
export interface Row {
  key: string;
  parent: string;
  position: number;
  payload: Json;
}
export async function rows(db: Surreal, table: string): Promise<Row[]> {
  const [found] = await run<[Row[]]>(db, "SELECT key, parent, position, payload FROM type::table($table)", { table });
  return found ?? [];
}
export async function rowsForParent(db: Surreal, table: string, parent: string): Promise<Row[]> {
  const [found] = await run<[Row[]]>(db, `SELECT key, parent, position, payload FROM type::table($table) WHERE parent = ${literal(parent)}`, { table });
  return found ?? [];
}
// One transaction: a write landing between separate reads would make a record and its projections disagree.
export async function rowsTogether(db: Surreal, reads: ({ table: string; key: string } | { table: string; parent: string })[]): Promise<Row[][]> {
  const vars: Record<string, string> = {};
  const statements = reads.map((read, index) => {
    vars[`t${index}`] = read.table;
    if ("key" in read) {
      vars[`k${index}`] = read.key;
      return `SELECT key, parent, position, payload FROM type::record($t${index}, $k${index})`;
    }
    return `SELECT key, parent, position, payload FROM type::table($t${index}) WHERE parent = ${literal(read.parent)}`;
  });
  // BEGIN and COMMIT answer too, with nothing.
  const found = (await run<Row[][]>(db, `BEGIN TRANSACTION; ${statements.join("; ")}; COMMIT TRANSACTION;`, vars)).slice(1, -1);
  if (found.length !== reads.length) throw Error("Lectura de la biblioteca incompleta");
  return found.map((rows) => rows ?? []);
}
export async function rowByKey(db: Surreal, table: string, key: string): Promise<Row | undefined> {
  const [found] = await run<[Row[]]>(db, "SELECT key, parent, position, payload FROM type::record($table, $key)", { table, key });
  return found?.[0];
}
