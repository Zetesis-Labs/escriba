import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller";
import { snapshot, runtimeContext } from "./fixture";
import type { RuntimeHost } from "../../src/runtime/contracts";
import { RuntimeError, errorCode } from "../../src/runtime/contracts";

function fixture() {
  const state = structuredClone(snapshot);
  state.providers = [{ id: "agenda", name: "Agenda", capability: "http", origin: "https://agenda.example", allowedHeaders: ["content-type"], credential: { label: "Clave", header: "X-API-Key" }, defaultConfiguration: {}, program: "agenda-program" }];
  state.accounts = [{ id: "a", name: "Trabajo", provider: "agenda", enabled: true, grant: { capability: "http", origin: "https://agenda.example", allowedHeaders: ["content-type"], credential: { label: "Clave", header: "X-API-Key" } } }];
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const host: RuntimeHost = { call: async (method, params = {}) => {
    calls.push({ method, params });
    if (method === "runtime_context") return { ...runtimeContext(state, params.recordingId), providers: state.providers };
    if (method === "connector_http") return { status: 200, headers: {}, body: '{}' };
    if (method === "account_effect_begin") state.recordings[0].accountEffectPending = true;
    if (method === "account_effect_finish") state.recordings[0].accountEffectPending = false;
    return null;
  } };
  return { state, calls, host };
}

test("el editor ejecuta el proveedor del proyecto y describe sin permisos externos", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (task, context) => {
    assert.equal(task.program, "agenda-program");
    assert.equal(task.payload.provider, "agenda");
    assert.deepEqual(task.payload.config, { board: "b" });
    await assert.rejects(context.call("connector.http", { url: "https://agenda.example/v1" }), /capacidades|permite|lectura/);
    return { view: { sections: [{ title: "Agenda", fields: [{ type: "text", path: ["board"], label: "Tablero" }] }] } };
  } });
  const result = await runtime.connectorEditor("describe", { providerId: "agenda", accountId: "a", configuration: { board: "b" } });
  assert.equal(result.view?.sections[0].title, "Agenda");
  assert.equal(f.calls.filter((call) => call.method === "connector_http").length, 0);
});

test("un formulario mal formado o con rutas de prototipo no llega a la interfaz", async () => {
  for (const view of [{ sections: "no es una lista" }, { sections: [{ fields: [{ type: "text", label: "Campo", path: ["__proto__", "polluted"] }] }] }]) {
    const f = fixture();
    const runtime = createRuntime(f.host, { run: async () => ({ view }) });
    await assert.rejects(runtime.connectorEditor("describe", { providerId: "agenda", configuration: {} }), /formulario inválido/);
  }
});

test("cambiar el origen solicitado corta la siguiente llamada de una receta ya cargada", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    await context.call("account.http", { accountId: "a", url: "https://agenda.example/items" });
    f.state.providers![0].origin = "https://other.example";
    await context.call("account.http", { accountId: "a", url: "https://agenda.example/items" });
    return null;
  } });
  await assert.rejects(runtime.processRecording("r"), /permisos.*han cambiado/);
  assert.equal(f.calls.filter((call) => call.method === "connector_http").length, 1);
});

test("una escritura SDK incierta se marca antes de enviar y no se repite automáticamente", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    await context.call("account.http", { accountId: "a", url: "https://agenda.example/items", method: "POST" });
    throw new RuntimeError("Servicio desconectado", "backend_unavailable");
  } });
  await assert.rejects(runtime.processRecording("r"), (error) => {
    assert.equal(errorCode(error), "failed");
    assert.match(String(error), /operación externa/);
    return true;
  });
  assert.equal(f.state.recordings[0].accountEffectPending, true);
  const methods = f.calls.map((call) => call.method);
  assert.ok(methods.indexOf("account_effect_begin") < methods.indexOf("connector_http"));
  await assert.rejects(runtime.processRecording("r", { force: false }), /Revisa la operación externa/);
  assert.equal(f.calls.filter((call) => call.method === "connector_http").length, 1);
  await assert.rejects(runtime.processRecording("r", { force: true }), /operación externa/);
  assert.equal(f.calls.filter((call) => call.method === "connector_http").length, 2);
  assert.equal(f.calls.filter((call) => call.method === "account_effect_finish").length, 1);
});

test("la prueba de receta deniega escrituras SDK antes de marcar o enviar", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    await context.call("account.http", { accountId: "a", url: "https://agenda.example/items", method: "POST" });
    return null;
  } });
  await assert.rejects(runtime.processRecording("r", { dryRun: true }), /no permite escrituras/);
  assert.equal(f.calls.some((call) => ["account_effect_begin", "connector_http"].includes(call.method)), false);
});

test("el marcador de escritura sobrevive al éxito hasta la siguiente ejecución manual", async () => {
  const f = fixture();
  const runtime = createRuntime({ call: async (method, params = {}) => {
    if (method === "transcribe") return { text: "Sintético", segments: [] };
    if (method === "version_save") return { ...params, id: "v", createdAt: "now" };
    return f.host.call(method, params);
  } }, { run: async (_, context) => {
    await context.call("transcribe", {});
    await context.call("account.http", { accountId: "a", url: "https://agenda.example/items", method: "POST" });
    return null;
  } });
  assert.deepEqual(await runtime.processRecording("r"), { versionId: "v" });
  assert.equal(f.state.recordings[0].accountEffectPending, true);
  assert.equal(f.calls.some((call) => call.method === "account_effect_finish"), false);
});

test("el transporte SDK rechaza otro origen y la sustitución de la credencial", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    await assert.rejects(context.call("account.http", { accountId: "a", url: "https://other.example/items" }), /fuera de la cuenta/);
    await assert.rejects(context.call("account.http", { accountId: "a", url: "https://agenda.example/items", headers: { "X-API-Key": "fake" } }), /Cabecera.*no permitida/);
    throw Error("Comprobación terminada");
  } });
  await assert.rejects(runtime.processRecording("r"), /Comprobación terminada/);
  assert.equal(f.calls.some((call) => call.method === "connector_http"), false);
});

test("una acción modular usa la cuenta autorizada y falla al revocarla", async () => {
  const f = fixture();
  const runtime = createRuntime(f.host, { run: async (_, context) => {
    await context.call("connector.http", { url: "https://agenda.example/query", method: "POST", headers: { "content-type": "application/json" }, body: '{}' });
    f.state.accounts[0].enabled = false;
    await assert.rejects(context.call("connector.http", { url: "https://agenda.example/query" }), /desactivada|revocada/);
    return { state: { boards: ["b"] } };
  } });
  const result = await runtime.connectorEditor("action", { providerId: "agenda", accountId: "a", action: "connect", configuration: {} });
  assert.deepEqual(result.state, { boards: ["b"] });
  assert.equal(f.calls.filter((call) => call.method === "connector_http").length, 1);
  assert.deepEqual(f.calls.find((call) => call.method === "connector_http")?.params.expectedGrant, f.state.accounts[0].grant);
});

test("instalar un proveedor externo no necesita crear su cuenta por adelantado", async () => {
  const f = fixture();
  f.state.providers = [];
  f.state.accounts = [];
  const provider = { id: "agenda", name: "Agenda", capability: "http", origin: "https://agenda.example", allowedHeaders: ["content-type"], defaultConfiguration: { board: "" } };
  const runtime = createRuntime({ call: async (method, params = {}) => {
    if (method === "shell.project_build") return { recipes: [], connectorProgram: "external" };
    return f.host.call(method, params);
  } }, { run: async () => ({ destinations: [], providers: [provider] }) });
  await runtime.rebuildProject();
  assert.deepEqual(f.calls.find((call) => call.method === "project_install")?.params.providers, [{ ...provider, program: "external" }]);
});

test("publicar con un proveedor externo usa su transporte y conserva el programa", async () => {
  const f = fixture();
  f.state.recordings[0].versions = [{ id: "v", createdAt: "now", backend: "local-stt", transcript: { text: "Sintético", segments: [] } }];
  f.state.destinations = [{ id: "a", account: "a", name: "Agenda", provider: "agenda", enabled: true, configuration: {}, program: "agenda-program", managed: true }];
  const runtime = createRuntime(f.host, { run: async (task, context) => {
    assert.equal(task.program, "agenda-program");
    assert.equal(task.payload.destination, undefined);
    await context.call("connector.http", { url: "https://agenda.example/items", method: "POST", body: '{}' });
    return { receipt: { locator: "item-1", provider: "agenda" } };
  } });
  await runtime.publishRecording("r", "a");
  const saved = f.calls.filter((call) => call.method === "publication_save").at(-1)?.params;
  assert.equal(saved?.managed, true);
  assert.equal(saved?.program, "agenda-program");
});
