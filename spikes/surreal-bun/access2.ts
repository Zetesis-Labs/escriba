import { Surreal } from "surrealdb";
import { createNodeEngines } from "@surrealdb/node";
const path = process.argv[2];
const engines = createNodeEngines();
const db = new Surreal({ engines });
await db.connect(`rocksdb://${path}`, { namespace: "k", database: "o" });
await db.query(`
  DEFINE TABLE IF NOT EXISTS thing SCHEMAFULL PERMISSIONS FOR select FULL FOR create, update, delete NONE;
  DEFINE FIELD IF NOT EXISTS title ON thing TYPE string;
  DEFINE TABLE IF NOT EXISTS principal PERMISSIONS NONE;
  UPSERT principal:runtime;
  DEFINE ACCESS OVERWRITE recipe ON DB TYPE RECORD SIGNIN (RETURN principal:runtime) DURATION FOR SESSION 1h;
  DEFINE USER OVERWRITE admin ON DB PASSWORD 'pw' ROLES OWNER;
  UPSERT thing:a CONTENT { title: 'a' };
`);
const show = async (label: string) => {
  const [sel] = await db.query<[unknown[]]>("SELECT VALUE title FROM thing").catch((e) => [["err:" + String(e).slice(0, 50)]]);
  const cr = await db.query("CREATE thing CONTENT { title: 'x' }").then(() => "creó").catch((e) => "denegado: " + String(e).slice(0, 40));
  console.log(label, "select", JSON.stringify(sel), "|", cr);
};
await db.signin({ namespace: "k", database: "o", access: "recipe" } as never);
await show("como receta  ");
await db.signin({ namespace: "k", database: "o", username: "admin", password: "pw" } as never);
await show("como admin   ");
const second = new Surreal({ engines });
const ok = await second.connect(`rocksdb://${path}`, { namespace: "k", database: "o" }).then(() => "segunda instancia con mismos engines: conecta").catch((e) => "segunda instancia: " + String(e).slice(0, 40));
console.log(ok);
await second.close().catch(() => {});
await db.close();
