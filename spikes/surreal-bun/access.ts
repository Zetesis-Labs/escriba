import { Surreal } from "surrealdb";
import { createNodeEngines } from "@surrealdb/node";
const path = process.argv[2];
const root = new Surreal({ engines: createNodeEngines() });
await root.connect(`rocksdb://${path}`, { namespace: "k", database: "o" });
await root.query(`
  DEFINE TABLE IF NOT EXISTS thing SCHEMAFULL PERMISSIONS FOR select FULL FOR create, update, delete NONE;
  DEFINE FIELD IF NOT EXISTS title ON thing TYPE string;
  DEFINE TABLE IF NOT EXISTS principal PERMISSIONS NONE;
  UPSERT principal:runtime;
  DEFINE ACCESS OVERWRITE recipe ON DB TYPE RECORD SIGNIN (RETURN principal:runtime) DURATION FOR SESSION 1h;
  UPSERT thing:a CONTENT { title: 'a' };
`);
await root.query("BEGIN; CREATE thing:b CONTENT { title: 'b' }; CANCEL;").catch((e) => console.log("cancel:", String(e).slice(0, 50)));
const [n] = await root.query<[{ count: number }[]]>("SELECT count() FROM thing GROUP ALL");
console.log("tras CANCEL", JSON.stringify(n));
const recipe = new Surreal({ engines: createNodeEngines() });
await recipe.connect(`rocksdb://${path}`, { namespace: "k", database: "o" }).catch((e) => console.log("segunda conexión:", String(e).slice(0, 80)));
const session = recipe;
try {
  await session.signin({ namespace: "k", database: "o", access: "recipe" } as never);
  console.log("signin record OK");
  const [sel] = await session.query<[unknown[]]>("SELECT title FROM thing");
  console.log("select como receta", JSON.stringify(sel));
  const r = await session.query("CREATE thing:c CONTENT { title: 'c' }").catch((e) => "err:" + String(e).slice(0, 60));
  console.log("create como receta", typeof r === "string" ? r : JSON.stringify(r));
} catch (e) { console.log("signin falló:", String(e).slice(0, 120)); }
await recipe.close(); await root.close();
