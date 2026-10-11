import { test } from "node:test";
import assert from "node:assert/strict";
import { z } from "zod";
import { builtinProviders, createProgram, defineProvider, run } from "../src/index.js";
import type { ConnectorView } from "../src/protocol.js";

function view(result: { [key: string]: unknown }): ConnectorView {
  assert.ok(result.view);
  return result.view as ConnectorView;
}
test("un proveedor externo declara esquema, vista, acciones y operaciones sin código en el host", async () => {
  const provider = defineProvider({
    manifest: { id: "synthetic", name: "Synthetic", capability: "http", origin: "https://example.test", allowedHeaders: [], defaultConfiguration: { project: "test" } },
    configurationSchema: z.object({ project: z.string().min(1) }),
    describe: (configuration) => ({ view: { sections: [{ title: "Proyecto", fields: [{ type: "text", path: ["project"], label: "Proyecto" }] }], subtitle: String(configuration.project) } }),
    action: (configuration, state, action, value) => {
      assert.equal(action, "choose");
      return { configuration: { ...configuration, project: String(value) }, state };
    },
    run: async (request) => ({ resource: request.operation }),
  });
  const program = createProgram([{ id: "destination", name: "Demo", account: "account", provider: "synthetic", configuration: { project: "test" } }], [provider]);
  assert.equal(program.inspect().providers.find((entry) => entry.id === "synthetic")?.origin, "https://example.test");
  assert.equal(view(await program.run({ operation: "describe", provider: "synthetic", config: { project: "test" } })).sections[0].fields[0].type, "text");
  assert.deepEqual((await program.run({ operation: "action", provider: "synthetic", config: { project: "test" }, action: "choose", value: "next" })).configuration, { project: "next" });
  assert.match(String((await program.run({ operation: "validate", provider: "synthetic", config: { project: "" } })).problem), /project/);
  assert.equal((await program.run({ operation: "remove", destination: "destination" })).resource, "remove");
  assert.throws(() => defineProvider({ ...provider, manifest: { ...provider.manifest, id: "notion" } }), /reservado/);
  assert.throws(() => createProgram([], [provider, provider]), /repetido/);
});
test("Notion declara credencial aparte y genera campos y vista previa desde el borrador", async () => {
  const manifest = builtinProviders.find((entry) => entry.id === "notion");
  assert.equal(manifest?.credential?.header, "Authorization");
  assert.equal(manifest?.credential?.prefix, "Bearer ");
  const config = { source: { id: "db", title: "Notas", databaseTitle: "Notas", properties: [{ name: "Título", type: "title" }] }, columns: { "Título": "{{titulo}}" }, body: "# {{titulo}}" };
  const result = await run({ operation: "describe", provider: "notion", config });
  const sections = view(result).sections;
  assert.ok(sections.some((section) => section.fields.some((field) => field.type === "template" && field.path.join(".") === "columns.Título")));
  assert.equal(view(result).previews?.[0].properties?.[0].value, "Lanzamiento del jueves");
  const selected = await run({ operation: "action", provider: "notion", config, state: { sources: [config.source] }, action: "select-source", value: "db" });
  assert.deepEqual((selected.configuration as { columns: Record<string, string> }).columns, config.columns);
});
test("OKF expone documentos, propiedades y enlaces en el mismo contrato", async () => {
  const config = builtinProviders.find((entry) => entry.id === "okf")!.defaultConfiguration;
  const described = await run({ operation: "describe", provider: "okf", config });
  const fields = view(described).sections.flatMap((section) => section.fields);
  assert.ok(fields.some((field) => field.type === "folder" && field.path[0] === "folder"));
  assert.ok(fields.some((field) => field.type === "template" && field.context === "property" && field.links?.length));
  const added = await run({ operation: "action", provider: "okf", config, action: "add-document" });
  assert.equal((added.configuration as { documents: unknown[] }).documents.length, 3);
  const removed = await run({ operation: "action", provider: "okf", config: added.configuration as Record<string, unknown>, state: added.state as Record<string, unknown>, action: "remove-document" });
  assert.equal((removed.configuration as { documents: unknown[] }).documents.length, 2);
});

test("un destino propio prepara la entrada y conserva la configuración capturada al republicar", async () => {
  const observed: Array<{ config: unknown; text: string | undefined }> = [];
  const provider = defineProvider({
    manifest: { id: "capture", name: "Capture", capability: "folder", allowedHeaders: [], defaultConfiguration: { target: "current" } },
    configurationSchema: z.object({ target: z.string() }),
    describe: () => ({ view: { sections: [] } }),
    run: async (request) => {
      observed.push({ config: request.config, text: request.note?.text });
      return { locator: "captured" };
    },
  });
  const program = createProgram([{ id: "publish", name: "Publish", account: "account", provider: "capture", configuration: { target: "current" }, inputSchema: z.object({ text: z.string() }), prepare: (input) => {
    const data = z.object({ text: z.string() }).parse(input);
    return { key: "synthetic", startedAt: "2026-10-11T00:00:00Z", text: data.text.toUpperCase(), segments: [], source: "synthetic", timeZone: "UTC" };
  } }], [provider]);
  await program.run({ operation: "publish", destination: "publish", provider: "capture", input: { text: "hello" }, config: { target: "captured" } });
  assert.deepEqual(observed, [{ config: { target: "captured" }, text: "HELLO" }]);
});

test("el manifiesto rechaza orígenes y cabeceras que ampliarían la autoridad", () => {
  const base = { manifest: { id: "safe", name: "Safe", capability: "http" as const, origin: "https://example.test", allowedHeaders: ["accept"], defaultConfiguration: { project: "demo" } }, configurationSchema: z.object({ project: z.string() }), describe: () => ({ view: { sections: [] } }) };
  assert.throws(() => defineProvider({ ...base, manifest: { ...base.manifest, origin: "https://example.test/redirect" } }), /origen/);
  assert.throws(() => defineProvider({ ...base, manifest: { ...base.manifest, allowedHeaders: ["accept\r\nX-Evil"] } }), /Cabecera/);
  assert.throws(() => defineProvider({ ...base, manifest: { ...base.manifest, allowedHeaders: ["X-API-Key"], credential: { label: "Clave", header: "X-API-Key" } } }), /separadamente/);
});
test("los selectores declaran valor actual y Notion permite deseleccionar la base", async () => {
  assert.equal(builtinProviders.find((entry) => entry.id === "notion")?.connectAction, "refresh-sources");
  const okf = await run({ operation: "describe", provider: "okf", config: builtinProviders.find((entry) => entry.id === "okf")!.defaultConfiguration });
  const selector = view(okf).sections.flatMap((section) => section.fields).find((field) => field.type === "select" && field.action === "select-document");
  assert.equal(selector?.value, "nota");
  const source = { id: "source", title: "Notas", databaseTitle: "Notas", properties: [{ name: "Título", type: "title" }] };
  const cleared = await run({ operation: "action", provider: "notion", config: { source, columns: { "Título": "{{titulo}}" }, body: "Texto propio" }, state: { sources: [source] }, action: "select-source", value: "" });
  assert.deepEqual(cleared.configuration, { source: { id: "", title: "", databaseTitle: "", properties: [] }, columns: {}, body: "Texto propio" });
});
test("Notion actualiza las bases mediante la acción y conserva columnas manuales", async () => {
  const initial = { source: { id: "source", title: "Notas", databaseTitle: "Notas", properties: [{ name: "Nombre", type: "title" }] }, columns: { Nombre: "Texto manual" }, body: "{{transcripcion}}" };
  const host = { fetch: async () => new Response(JSON.stringify({ results: [{ object: "data_source", id: "source", title: [{ plain_text: "Notas" }], properties: { Nombre: { type: "title" }, Etiquetas: { type: "multi_select" } } }], has_more: false })), files: { snapshot: async () => ({}), apply: async () => {} }, audio: async () => null, checkpoint: async () => {} };
  const result = await run({ operation: "action", provider: "notion", config: initial, action: "refresh-sources" }, host);
  assert.equal((result.configuration as { columns: Record<string, string> }).columns.Nombre, "Texto manual");
  assert.equal((result.state as { sources: unknown[] }).sources.length, 1);
  assert.ok(view(result).sections.some((section) => section.fields.some((field) => field.type === "template" && field.path.join(".") === "columns.Etiquetas")));
});
test("un documento OKF malformado falla señalando el campo sin desaparecer del formulario", async () => {
  await assert.rejects(() => run({ operation: "describe", provider: "okf", config: { folder: "/bundle", documents: [{ id: "a", name: "A", path: "a.md", properties: [{ key: "type", value: "A" }, null], body: "" }] } }), /documents\.0\.properties\.1/);
});
