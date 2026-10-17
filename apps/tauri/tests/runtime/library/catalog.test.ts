import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { mkdirSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { install } from "../../../src/runtime/library/catalog";
import { fileCredentials } from "../../../src/runtime/credentials";
import { arr, obj, str, workspace, reopen, type Workspace } from "./fixture";

let space: Workspace;
beforeEach(async () => {
  space = await workspace();
});
afterEach(async () => {
  await space.dispose();
});

test("las ontologías del catálogo se validan y persisten sin inflar la lista", async () => {
  let store = await space.open(space.dir);
  const ontology = { id: "example", name: "Ejemplo", version: 1, migrations: [{ version: 1, sql: "DEFINE TABLE topic PERMISSIONS FULL;" }], collections: [] };
  const pkg = { recipes: [], destinations: [], ontologies: [ontology] };
  await install(store, pkg);
  assert.equal(obj(store.library().settings).projectOntologies, undefined);
  store = await reopen(space, store, space.dir);
  assert.deepEqual(store.data.settings.projectOntologies, pkg.ontologies);
  const invalid = JSON.parse(JSON.stringify(pkg));
  invalid.ontologies[0].version = 2;
  await assert.rejects(install(store, invalid));
  assert.deepEqual(store.data.settings.projectOntologies, pkg.ontologies);
  await install(store, { recipes: [], destinations: [] });
  assert.deepEqual(store.data.settings.projectOntologies, []);
});

test("un proveedor del proyecto sobrevive a la reapertura y a su retirada sin perder la cuenta", async () => {
  let store = await space.open(space.dir);
  const provider = { id: "example", name: "Example", capability: "http", origin: "https://example.org", allowedHeaders: ["x-api-version"], credential: { label: "Token", header: "x-api-key" }, defaultConfiguration: {}, program: "compiled" };
  await install(store, { recipes: [], destinations: [], providers: [provider] });
  assert.equal(store.item("providers", "example").program, "compiled");
  store = await reopen(space, store, space.dir);
  assert.equal(arr((await store.runtimeContext()).providers)[0]!.origin, "https://example.org");
  await store.saveConnector({ id: "draft", name: "Draft", provider: "example", enabled: false }, { id: "draft", name: "Draft", account: "draft", provider: "example", enabled: false, configuration: {} });
  assert.equal(store.item("accounts", "draft").enabled, false);
  assert.equal(store.item("accounts", "draft").grant, undefined);
  await store.saveConnector({ id: "a", name: "A", provider: "example", grant: { capability: "http", origin: "https://example.org", allowedHeaders: ["x-api-version"], credential: { label: "Token", header: "x-api-key" } } }, { id: "a", name: "A", account: "a", provider: "example", enabled: true, configuration: {} });
  assert.equal(store.item("destinations", "a").managed, true);
  assert.equal(store.item("destinations", "a").program, "compiled");
  await fileCredentials(space.dir).save("a", "synthetic-token");
  await assert.rejects(store.mutate("config_save", { collection: "accounts", item: { id: "a", name: "Notion", provider: "notion", enabled: true } }));
  assert.equal(store.credential("a"), "synthetic-token");
  const account = store.item("accounts", "a");
  account.enabled = false;
  await store.saveConnector(account, store.item("destinations", "a"));
  assert.equal(store.item("accounts", "a").enabled, false);
  const changed = store.item("providers", "example");
  changed.program = "updated";
  await install(store, { recipes: [], destinations: [], providers: [changed] });
  assert.equal(store.item("destinations", "a").program, "updated");
  assert.equal(store.item("destinations", "a").enabled, true);
  await install(store, { recipes: [], destinations: [], providers: [] });
  assert.equal(store.item("providers", "example").unavailable, true);
  assert.equal(store.item("providers", "example").program, "updated");
  assert.equal(store.item("destinations", "a").program, "updated");
  assert.equal(store.item("accounts", "a").provider, "example");
});

test("instalar recetas con notas descartadas conserva el descarte", async () => {
  const audio = space.path("prueba.wav");
  writeFileSync(audio, "audio sintetico");
  let store = await space.open();
  const record = obj(await store.import(audio));
  const discarded = await store.mutate("recording_discard", { id: record.id });
  await install(store, { recipes: [{ id: "ejemplo", kind: "code", name: "Ejemplo", values: {}, bundle: "compiled" }], destinations: [] });
  assert.equal(store.item("recipes", "ejemplo").bundle, "compiled");
  assert.deepEqual(await store.recording(str(record.id)), discarded);
  store = await reopen(space, store);
  assert.equal(store.item("recipes", "ejemplo").bundle, "compiled");
  assert.deepEqual(await store.import(audio), discarded);
});

test("compilar la disposición antigua conserva valores, receta por defecto y base del formulario", async () => {
  let store = await space.open(space.dir);
  await store.mutate("config_save", { collection: "recipes", item: { id: "code:recetas:meeting", kind: "code", entry: "recetas/meeting/receta.js", name: "Meeting", values: { idioma: "en" }, bundle: "old" } });
  await store.mutate("config_save", { collection: "recipes", item: { id: "custom", kind: "form", name: "Custom", base: "code:recetas:meeting", values: {} } });
  await store.mutate("settings_save", { settings: { defaultRecipeId: "code:recetas:meeting" } });
  const audio = space.path("activa.wav");
  writeFileSync(audio, "audio activo sintetico");
  const active = obj(await store.import(audio, "code:recetas:meeting"));
  const version = obj(await store.mutate("version_save", { recordingId: active.id, recipeId: "code:recetas:meeting", transcript: { text: "contenido sintetico", segments: [] } }));
  const discardedAudio = space.path("descartada.wav");
  writeFileSync(discardedAudio, "audio descartado sintetico");
  const discarded = obj(await store.import(discardedAudio));
  const tombstone = await store.mutate("recording_discard", { id: discarded.id });
  await install(store, { recipes: [{ id: "meeting", kind: "code", entry: "recetas/meeting/receta.js", name: "Meeting", values: {}, bundle: "new" }], destinations: [] });
  assert.equal(obj(store.item("recipes", "meeting").values).idioma, "en");
  assert.equal(store.item("recipes", "custom").base, "meeting");
  assert.equal(obj(store.settingsJson()).defaultRecipeId, "meeting");
  assert.throws(() => store.item("recipes", "code:recetas:meeting"));
  store = await reopen(space, store, space.dir);
  const restored = await store.recording(str(active.id));
  assert.equal(restored.recipeId, "meeting");
  assert.equal(restored.currentVersionId, version.id);
  assert.equal(arr(restored.versions)[0]!.recipeId, "meeting");
  assert.deepEqual(arr(restored.versions)[0]!.transcript, version.transcript);
  assert.deepEqual(await store.recording(str(discarded.id)), tombstone);
});

test("una receta sin código conserva sus parámetros pero no puede ejecutar un programa viejo", async () => {
  const store = await space.open(space.dir);
  await store.mutate("config_save", { collection: "recipes", item: { id: "missing", kind: "code", entry: "recetas/missing/receta.ts", name: "Missing", values: { language: "en" }, bundle: "old" } });
  await install(store, { recipes: [], destinations: [] });
  const missing = store.item("recipes", "missing");
  assert.equal(obj(missing.values).language, "en");
  assert.equal(missing.bundle, undefined);
  assert.equal(typeof missing.error, "string");
});

test("compilar conserva los destinos de la app y sustituye los del proyecto", async () => {
  const store = await space.open(space.dir);
  await store.mutate("config_save", { collection: "destinations", item: { id: "app", name: "App", provider: "okf", account: "app", enabled: true, configuration: { folder: "/tmp" } } });
  await store.mutate("config_save", { collection: "destinations", item: { id: "code", name: "Old", provider: "notion", account: "code", enabled: true, configuration: {}, program: "old" } });
  await install(store, { recipes: [], destinations: [{ id: "code", name: "New", provider: "notion", account: "code", enabled: false, configuration: {}, program: "new" }] });
  assert.equal(obj(store.item("destinations", "app").configuration).folder, "/tmp");
  assert.equal(store.item("destinations", "code").program, "new");
  assert.equal(arr(store.data.destinations).length, 2);
});

test("compilar rechaza un id de proyecto que pertenece a un destino de la app", async () => {
  const store = await space.open(space.dir);
  await store.mutate("config_save", { collection: "destinations", item: { id: "same", name: "App", provider: "okf", account: "same", enabled: true, configuration: {} } });
  await assert.rejects(install(store, { recipes: [], destinations: [{ id: "same", name: "Project", provider: "okf", account: "same", enabled: true, configuration: {}, program: "new" }] }), /Identificador duplicado/);
  assert.equal(store.item("destinations", "same").name, "App");
});

test("el proyecto no puede marcar su destino como gestionado por la app", async () => {
  const store = await space.open(space.dir);
  await install(store, { recipes: [], destinations: [{ id: "external", name: "External", provider: "notion", account: "a", enabled: true, configuration: {}, program: "compiled", managed: true }] });
  assert.equal(store.item("destinations", "external").managed, undefined);
  await install(store, { recipes: [], destinations: [] });
  assert.throws(() => store.item("destinations", "external"));
});

test("un proveedor de carpeta autoriza después de guardar un borrador", async () => {
  const folder = space.path("documents");
  mkdirSync(folder);
  const store = await space.open();
  await install(store, { recipes: [], destinations: [], providers: [{ id: "documents", name: "Documents", capability: "folder", allowedHeaders: [], defaultConfiguration: {}, program: "compiled" }] });
  const account: Record<string, unknown> = { id: "folder", name: "Folder", provider: "documents", enabled: false };
  const destination: Record<string, unknown> = { id: "folder", name: "Folder", provider: "documents", account: "folder", enabled: false, configuration: {} };
  await store.saveConnector(account as never, destination as never);
  assert.equal(store.item("accounts", "folder").grant, undefined);
  account.enabled = true;
  account.grant = { capability: "folder", allowedHeaders: [] };
  account.folder = folder;
  (destination.configuration as Record<string, unknown>).folder = space.path("alias");
  symlinkSync(folder, space.path("alias"), process.platform === "win32" ? "junction" : "dir");
  destination.enabled = true;
  await store.saveConnector(account as never, destination as never);
  const saved = store.item("accounts", "folder");
  assert.equal(saved.folder, realpathSync(folder));
  assert.equal(obj(store.item("destinations", "folder").configuration).folder, saved.folder);
  assert.deepEqual(saved.grant, account.grant);
});
