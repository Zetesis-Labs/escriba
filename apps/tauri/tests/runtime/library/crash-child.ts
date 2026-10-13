import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { Store } from "../../../src/runtime/library/store";

const root = process.argv[2]!;
const store = await Store.open(root);
await store.mutate("log", { message: "committed before kill" });
writeFileSync(join(root, "child-ready"), "");
await new Promise(() => undefined);
