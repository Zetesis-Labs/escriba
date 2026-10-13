import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store, type StoreOptions } from "../../../src/runtime/library/store";
import type { Json } from "../../../src/runtime/library/json";

export type Obj = Record<string, Json>;
export const obj = (value: unknown) => value as Obj;
export const arr = (value: unknown) => value as Obj[];
export const str = (value: unknown) => value as string;

export async function workspace() {
  const dir = await mkdtemp(join(tmpdir(), "escriba-store-"));
  const opened: Store[] = [];
  return {
    dir,
    path: (name: string) => join(dir, name),
    library: join(dir, "library"),
    async open(root = join(dir, "library"), options: StoreOptions = {}) {
      const store = await Store.open(root, options);
      opened.push(store);
      return store;
    },
    async close(store: Store) {
      await store.close();
      opened.splice(opened.indexOf(store), 1);
    },
    async dispose() {
      for (const store of opened.splice(0)) await store.close().catch(() => undefined);
      await rm(dir, { recursive: true, force: true });
    },
  };
}
export type Workspace = Awaited<ReturnType<typeof workspace>>;
export async function reopen(space: Workspace, store: Store, root?: string) {
  await space.close(store);
  return space.open(root);
}
