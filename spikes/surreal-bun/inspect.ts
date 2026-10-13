import { Surreal } from "surrealdb";
import { createNodeEngines } from "@surrealdb/node";
const [path, ns, dbName] = [process.argv[2], process.argv[3] ?? "escriba", process.argv[4]];
const db = new Surreal({ engines: createNodeEngines() });
await db.connect(`rocksdb://${path}`);
if (dbName) {
  await db.use({ namespace: ns, database: dbName });
  const [info] = await db.query<[{ tables: Record<string, string> }]>("INFO FOR DB");
  const tables = Object.keys(info.tables);
  console.log("tables", tables.length);
  for (const t of tables) {
    const [rows] = await db.query<[{ count: number }[]]>(`SELECT count() FROM ${t} GROUP ALL`);
    console.log(t.padEnd(24), rows[0]?.count ?? 0);
  }
  if (tables.includes("meta")) {
    const [meta] = await db.query<[{ id: unknown; value?: unknown }[]]>("SELECT id, value FROM meta");
    console.log("meta", JSON.stringify(meta));
  }
} else {
  const [root] = await db.query<[{ namespaces: Record<string, string> }]>("INFO FOR ROOT");
  console.log("namespaces", Object.keys(root.namespaces));
  for (const n of Object.keys(root.namespaces)) {
    await db.use({ namespace: n });
    const [info] = await db.query<[{ databases: Record<string, string> }]>("INFO FOR NS");
    console.log(n, "databases", Object.keys(info.databases));
  }
}
await db.close();
