import { test } from "vitest";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createCommands, registerControllerCommands } from "../../src/runtime/commands";
import { UI_CONTROLLER_METHODS } from "../../src/runtime/controllerMethods";
import { memoryCredentials } from "../../src/runtime/credentials";
import type { RuntimeHost } from "../../src/runtime/contracts";
import { runtimeContext, snapshot } from "./fixture";

function fixture(transport?: (request: Request) => Promise<Response>) {
  const state = structuredClone(snapshot);
  state.accounts = [{ id: "notion-a", name: "Trabajo", provider: "notion", enabled: true }];
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const events: string[] = [];
  const host: RuntimeHost = {
    async call(method, params = {}) {
      calls.push({ method, params });
      if (method === "runtime_context") return runtimeContext(state, params.recordingId);
      if (method === "shell.audio_path") return { path: "/ruta/opaca.m4a" };
      if (method === "shell.native") return { title: "Local", summary: "resumen", tags: [] };
      throw Error(`Capacidad inesperada: ${method}`);
    },
  };
  const credentials = memoryCredentials({ "notion-a": "secreto-notion", "remote-llm": "clave-llm" });
  const commands = createCommands();
  registerControllerCommands(commands, { host, dataPath: "/datos", credentials, transport, emit: (event) => events.push(event) });
  return { state, calls, events, commands, credentials };
}

test("la lista de métodos reenviados por Rust coincide con la del controlador", () => {
  const source = readFileSync(fileURLToPath(new URL("../../src-tauri/src/command.rs", import.meta.url)), "utf8");
  const declared = /CONTROLLER_METHODS: &\[&str\] = &\[([^\]]*)\]/.exec(source)?.[1] ?? "";
  const rust = [...declared.matchAll(/"([a-z_]+)"/g)].map((match) => match[1]).sort();
  assert.deepEqual(rust, [...UI_CONTROLLER_METHODS].sort());
});

test("cada comando solo admite su origen y los desconocidos fallan nombrándolos", async () => {
  const f = fixture();
  await assert.rejects(f.commands.dispatch("credential_save", { id: "x", value: "" }, "shell"), /Origen no permitido/);
  await assert.rejects(f.commands.dispatch("inventado", {}, "ui"), /Método desconocido: inventado/);
  assert.deepEqual(await f.commands.dispatch("controller_status", {}, "ui"), { protocolVersion: 1, dataPath: "/datos" });
});

test("guardar una credencial exige una cuenta o resolutor existente y avisa del cambio", async () => {
  const f = fixture();
  await assert.rejects(f.commands.dispatch("credential_save", { id: "nadie", value: "x" }, "ui"), /La cuenta no existe/);
  await f.commands.dispatch("credential_save", { id: "local-stt", value: " clave " }, "ui");
  assert.equal(await f.credentials.read("local-stt"), "clave");
  assert.deepEqual(f.events, ["changed"]);
  await f.commands.dispatch("credential_save", { id: "notion-a", value: "" }, "ui");
  assert.equal(await f.credentials.read("notion-a"), undefined);
});

test("connector_http inyecta la credencial de la cuenta y el secreto no vuelve en la respuesta", async () => {
  const seen: Request[] = [];
  const f = fixture(async (request) => {
    seen.push(request);
    return new Response('{"ok":true,"echo":"secreto-notion"}', { status: 200, headers: { "content-type": "application/json", "request-id": "secreto-notion-1" } });
  });
  const result = (await f.commands.dispatch("connector_http", { accountId: "notion-a", url: "https://api.notion.com/v1/users", headers: { accept: "application/json" } }, "shell")) as { status: number; body: string; headers: Record<string, string> };
  assert.equal(result.status, 200);
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer secreto-notion");
  assert.ok(!result.body.includes("secreto-notion"));
  assert.equal(result.headers["request-id"], "[redacted]-1");
  await assert.rejects(f.commands.dispatch("connector_http", { accountId: "notion-a", url: "https://evil.example/v1" }, "shell"), /fuera del origen/);
  await assert.rejects(f.commands.dispatch("connector_http", { accountId: "nadie", url: "https://api.notion.com/v1" }, "ui"), /La cuenta no existe/);
  assert.ok(!f.calls.some((call) => call.method === "shell.audio_path"));
});

test("connector_http pide a la cáscara la ruta del audio solo cuando hay una parte de audio", async () => {
  const f = fixture(async () => new Response("{}", { status: 200 }));
  await assert.rejects(
    f.commands.dispatch("connector_http", { accountId: "notion-a", url: "https://api.notion.com/v1/upload", method: "POST", multipart: [{ name: "file", audio: { recordingId: "r" } }] }, "shell"),
    /Audio no disponible/,
  );
  assert.deepEqual(f.calls.filter((call) => call.method === "shell.audio_path").map((call) => call.params), [{ recordingId: "r" }]);
});

test("resolver_try usa el motor local por la cáscara y el remoto con la clave escrita o guardada", async () => {
  const seen: Request[] = [];
  const f = fixture(async (request) => {
    seen.push(request);
    if (request.url.endsWith("/chat/completions"))
      return new Response(JSON.stringify({ choices: [{ message: { content: '{"title":"T","summary":"S","tags":[]}' } }] }), { status: 200 });
    return new Response(JSON.stringify({ text: " hola " }), { status: 200 });
  });
  const local = await f.commands.dispatch("resolver_try", { resolver: { id: "local-llm", local: true }, role: "llm", instructions: "i", prompt: "p" }, "ui");
  assert.deepEqual(local, { title: "Local", summary: "resumen", tags: [] });
  assert.ok(f.calls.some((call) => call.method === "shell.native" && call.params.method === "summarize"));
  await assert.rejects(f.commands.dispatch("resolver_try", { resolver: { id: "local-stt", local: true }, role: "stt" }, "ui"), /no tiene prueba/);
  const remote = { url: "https://llm.example/v1", model: "m", local: false };
  const typed = await f.commands.dispatch("resolver_try", { resolver: remote, key: " escrita ", resolverId: "remote-llm", role: "llm", instructions: "i", prompt: "p" }, "ui");
  assert.deepEqual(typed, { title: "T", summary: "S", tags: [] });
  assert.equal(seen.at(-1)?.headers.get("authorization"), "Bearer escrita");
  await f.commands.dispatch("resolver_try", { resolver: remote, resolverId: "remote-llm", role: "llm", instructions: "i", prompt: "p" }, "ui");
  assert.equal(seen.at(-1)?.headers.get("authorization"), "Bearer clave-llm");
  const stt = await f.commands.dispatch("resolver_try", { resolver: remote, role: "stt" }, "ui");
  assert.deepEqual(stt, { text: "hola" });
  assert.equal(seen.at(-1)?.headers.get("authorization"), null);
});

