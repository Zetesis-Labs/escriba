import { test } from "vitest";
import assert from "node:assert/strict";
import { createRuntime } from "../../src/runtime/controller";
import { createConnectorService } from "../../src/runtime/connectors";
import { summarizeText } from "../../src/runtime/summary";
import type { RuntimeHost, RuntimeRunner } from "../../src/runtime/contracts";
import type { Publication, Version } from "../../src/types";
import { snapshot, runtimeContext } from "./fixture";
function memory() {
  const state = structuredClone(snapshot);
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const host: RuntimeHost = {
    call: async (method, params = {}) => {
      calls.push({ method, params });
      const record = state.recordings[0];
      if (method === "runtime_context") return runtimeContext(state, params.recordingId);
      if (method === "transcribe")
        return { text: "Conversación", segments: [] };
      if (method === "version_save") {
        const v = {
          ...params,
          id: `v${record.versions.length + 1}`,
          createdAt: "now",
        } as unknown as Version;
        record.versions.push(v);
        record.currentVersionId = v.id;
        return structuredClone(v);
      }
      if (method === "version_update") {
        Object.assign(
          record.versions.find((v) => v.id === params.versionId)!,
          Object.fromEntries(
            Object.entries(params).filter(
              ([k]) => k === "digest" || k === "data",
            ),
          ),
        );
      }
      if (method === "version_select")
        record.currentVersionId = String(params.versionId);
      if (method === "recording_update") Object.assign(record, params);
      if (method === "publication_save") {
        const p = { ...params, updatedAt: "now" } as unknown as Publication;
        record.publications = record.publications
          .filter((e) => e.destinationId !== p.destinationId)
          .concat(p);
      }
      if (method === "publication_remove") record.publications = [];
      return null;
    },
  };
  return { state, calls, host };
}
test("reprocesado manual crea versión, automático reutiliza, cambio de idioma transcribe", async () => {
  const m = memory();
  const controller = createRuntime(m.host, {
    run: async (task, context) => {
      await context.call("transcribe", {
        stt: "local-stt",
        idioma: (task.payload.values as { idioma?: string }).idioma,
      });
      await context.call("save", {});
      return null;
    },
  });
  await controller.processRecording("r");
  await controller.processRecording("r");
  assert.equal(m.state.recordings[0].versions.length, 2);
  assert.equal(m.calls.filter((c) => c.method === "transcribe").length, 1);
  await controller.processRecording("r", { force: false });
  assert.equal(m.state.recordings[0].versions.length, 2);
  await controller.processRecording("r", { language: "en" });
  assert.equal(m.state.recordings[0].versions.length, 3);
  assert.equal(m.calls.filter((c) => c.method === "transcribe").length, 2);
});
test("trocea y reduce con el mismo backend, cancelación detiene siguientes peticiones", async () => {
  const calls: Record<string, unknown>[] = [];
  const host: RuntimeHost = {
    call: async (_, params = {}) => {
      calls.push(params);
      return { title: "T", summary: "S", tags: [] };
    },
  };
  await summarizeText(host, "Una frase. ".repeat(80), "llm-selected", {
    capacity: 100,
  });
  assert.ok(calls.length > 8);
  assert.ok(calls.every((c) => c.resolverId === "llm-selected"));
  assert.match(String(calls.at(-1)?.prompt), /Integra estos resúmenes/);
  const abort = new AbortController();
  let count = 0;
  await assert.rejects(
    summarizeText(
      {
        call: async () => {
          count++;
          abort.abort();
          return { title: "T", summary: "S" };
        },
      },
      "Texto ".repeat(80),
      "selected",
      { capacity: 100, signal: abort.signal },
    ),
    /cancelado/,
  );
  assert.equal(count, 1);
});
function publicationFixture() {
  const m = memory();
  m.state.accounts.push({
    id: "a",
    name: "Carpeta",
    provider: "okf",
    enabled: true,
    folder: "/permitted",
  });
  m.state.destinations.push({
    id: "d",
    name: "Destino",
    provider: "okf",
    account: "a",
    enabled: true,
    configuration: { marker: "original" },
    program: "original-program",
  });
  m.state.recordings[0].versions.push({
    id: "v1",
    createdAt: "now",
    backend: "local",
    transcript: { text: "Texto", segments: [] },
  });
  return m;
}
test("una publicación importada se actualiza con el programa de serie y el mismo localizador", async () => {
  const m = publicationFixture();
  delete m.state.destinations[0].program;
  m.state.recordings[0].publications.push({
    destinationId: "d", accountId: "a", name: "Destino", provider: "okf",
    configuration: { marker: "original" }, updatedAt: "now",
    receipt: { version: 1, provider: "okf", locator: "notas/nota.md", state: "published" },
  });
  const service = createConnectorService(m.host, {
    run: async (task) => {
      assert.equal(task.program, "builtin");
      assert.equal(task.payload.destination, undefined);
      assert.equal((task.payload.previous as { locator: string }).locator, "notas/nota.md");
      return { receipt: task.payload.previous };
    },
  }, "builtin");
  await service.publish("r", "d");
});
test("guardar una plantilla de la app cambia la actualización sin crear otra publicación", async () => {
  const m = publicationFixture();
  delete m.state.destinations[0].program;
  const seen: unknown[] = [];
  const service = createConnectorService(m.host, {
    run: async (task) => {
      seen.push(task.payload.config);
      return { receipt: { version: 1, provider: "okf", locator: "notas/nota.md", state: "published" } };
    },
  }, "builtin");
  await service.publish("r", "d");
  m.state.destinations[0].configuration = { marker: "guardado" };
  await service.publish("r", "d");
  assert.deepEqual(seen, [{ marker: "original" }, { marker: "guardado" }]);
  assert.equal(m.state.recordings[0].publications[0].receipt.locator, "notas/nota.md");
});
test("checkpoint durable y configuración/programa originales sobreviven a eliminación del destino", async () => {
  const m = publicationFixture();
  let invocation = 0;
  const runner: RuntimeRunner = {
    run: async (task, context) => {
      invocation++;
      assert.equal(task.program, "original-program");
      assert.deepEqual(task.payload.config, { marker: "original" });
      if (invocation === 1) {
        await context.call("connector.checkpoint", {
          receipt: { locator: "saved", version: 1 },
        });
        throw Error("interrumpido después de crear");
      }
      assert.deepEqual(task.payload.previous, { locator: "saved", version: 1 });
      return { receipt: { locator: "saved", version: 1 } };
    },
  };
  const service = createConnectorService(m.host, runner, "builtin");
  await assert.rejects(service.publish("r", "d"), /interrumpido/);
  assert.equal(m.state.recordings[0].publications[0].receipt.locator, "saved");
  assert.equal(m.state.recordings[0].publications[0].accountId, "a");
  m.state.destinations = [];
  await service.remove("r", "d");
  assert.equal(m.state.recordings[0].publications.length, 0);
});
test("revocar cuenta entre lectura y efecto bloquea escritura y no reintenta creación incierta", async () => {
  const m = publicationFixture();
  let runs = 0;
  const service = createConnectorService(m.host, {
    run: async (_, context) => {
      runs++;
      m.state.accounts[0].enabled = false;
      await context.call("connector.apply", { changes: [] });
      return {};
    },
  });
  await assert.rejects(service.publish("r", "d"), /permisos han cambiado/);
  assert.equal(m.calls.filter((c) => c.method === "connector_files").length, 0);
  m.state.accounts[0].enabled = true;
  m.state.recordings[0].publications[0].receipt = { state: "running" };
  await assert.rejects(service.publish("r", "d"), /incierta/);
  assert.equal(runs, 1);
});
test("dos publicaciones concurrentes refrescan el recibo después de adquirir su turno", async () => {
  const m = publicationFixture();
  const seen: unknown[] = [];
  const service = createConnectorService(m.host, {
    run: async (task, context) => {
      seen.push(task.payload.previous);
      await new Promise((resolve) => setTimeout(resolve, 10));
      await context.call("connector.checkpoint", {
        receipt: { locator: "one" },
      });
      return { receipt: { locator: "one" } };
    },
  });
  await Promise.all([service.publish("r", "d"), service.publish("r", "d")]);
  assert.deepEqual(seen, [undefined, { locator: "one" }]);
});

test("fallo antes de efectos permite corregir configuración sin conservar preparación obsoleta", async () => {
  const m = publicationFixture();
  let first = true;
  const service = createConnectorService(m.host, {
    run: async (task) => {
      if (first) {
        first = false;
        throw Error("config inválida");
      }
      assert.deepEqual(task.payload.config, { marker: "corregido" });
      return { receipt: { locator: "good" } };
    },
  });
  await assert.rejects(service.publish("r", "d"), /inválida/);
  m.state.destinations[0].configuration = { marker: "corregido" };
  await service.publish("r", "d");
  assert.deepEqual(m.state.recordings[0].publications[0].configuration, {
    marker: "corregido",
  });
});
test("catálogo se instala solo después de inspeccionar todo y conserva ajustes", async () => {
  const m = publicationFixture();
  m.state.destinations[0].enabled = false;
  m.state.recipes.push({
    id: "code",
    name: "Anterior",
    kind: "code",
    values: { idioma: "en" },
    bundle: "old",
  });
  const installed: Record<string, unknown>[] = [];
  const host: RuntimeHost = {
    call: async (method, params) => {
      if (method === "project_build")
        return {
          recipes: [
            {
              id: "code",
              name: "Archivo",
              entry: "r/receta.ts",
              bundle: "new",
            },
          ],
          connectorProgram: "connectors",
        };
      if (method === "project_install") {
        installed.push(params!);
        return null;
      }
      return m.host.call(method, params);
    },
  };
  let fail = true;
  const controller = createRuntime(host, {
    run: async (task) => {
      if (task.kind === "connector-inspect")
        return {
          destinations: [
            {
              id: "d",
              name: "Destino",
              account: "a",
              provider: "okf",
              configuration: { updated: true },
            },
          ],
        };
      if (fail) throw Error("esquema inválido");
      return {
        schema: { type: "object" },
        name: "Nombre declarado",
        description: "Descripción",
      };
    },
  });
  await assert.rejects(controller.rebuildProject(), /esquema inválido/);
  assert.equal(installed.length, 0);
  fail = false;
  await controller.rebuildProject();
  assert.deepEqual((installed[0].recipes as { values: unknown }[])[0].values, {
    idioma: "en",
  });
  assert.equal(
    (installed[0].destinations as { enabled: boolean }[])[0].enabled,
    false,
  );
  assert.equal(
    (installed[0].recipes as { name: string }[])[0].name,
    "Nombre declarado",
  );
});
test("cancelar grabación en cola no cancela el proceso nativo de otra grabación", async () => {
  const m = memory();
  m.state.recordings.push({
    ...structuredClone(m.state.recordings[0]),
    id: "queued",
  });
  let complete!: () => void;
  const pending = new Promise<void>((resolve) => {
    complete = resolve;
  });
  let entered!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const host: RuntimeHost = {
    call: async (method, params) => {
      if (method === "transcribe") {
        entered();
        await pending;
      }
      return m.host.call(method, params);
    },
  };
  const controller = createRuntime(host, {
    run: async (_, context) => {
      await context.call("transcribe", {});
      await context.call("save", {});
      return null;
    },
  });
  const active = controller.processRecording("r");
  await started;
  const queued = controller.processRecording("queued");
  const rejected = assert.rejects(queued, /cancelado/);
  controller.cancelProcessing("queued");
  assert.equal(m.calls.filter((c) => c.method === "native_cancel").length, 0);
  complete();
  await active;
  await rejected;
  assert.equal(controller.getJobs().length, 0);
});
test("validación y descubrimiento no permiten escrituras HTTP sin recibo", async () => {
  const m = memory();
  m.state.accounts.push({
    id: "a",
    name: "Notion",
    provider: "notion",
    enabled: true,
    origin: "https://api.notion.com",
  });
  m.state.destinations.push({
    id: "d",
    name: "Notas",
    provider: "notion",
    account: "a",
    enabled: true,
    configuration: {},
  });
  const service = createConnectorService(m.host, {
    run: async (_, context) =>
      context.call("connector.http", {
        url: "https://api.notion.com/v1/pages",
        method: "POST",
        headers: {},
        body: "{}",
      }),
  });
  await assert.rejects(service.validate("d"), /solo permite lecturas/);
  assert.equal(m.calls.filter((c) => c.method === "connector_http").length, 0);
});
test("cambiar Whisper en ajustes invalida reuso aunque el resolver conserve su modelo anterior", async () => {
  const m = memory();
  m.state.resolvers[0].model = "old-whisper";
  m.state.settings.whisperModel = "old-whisper";
  const runtime = createRuntime(m.host, {
    run: async (_, context) => {
      await context.call("transcribe", { stt: "local-stt" });
      await context.call("save", {});
      return null;
    },
  });
  await runtime.processRecording("r", { force: false });
  m.state.settings.whisperModel = "new-whisper";
  await runtime.processRecording("r", { force: false });
  assert.equal(m.calls.filter((c) => c.method === "transcribe").length, 2);
  assert.equal(
    m.state.recordings[0].versions.at(-1)?.inputs?.model,
    "new-whisper",
  );
});
test("resumen local de 4000 caracteres se trocea antes de reducir a un resumen final", async () => {
  const m = memory();
  m.state.recordings[0].versions.push({
    id: "long",
    createdAt: "now",
    backend: "local-stt",
    transcript: { text: "Texto ".repeat(667), segments: [] },
  });
  const prompts: string[] = [];
  const runtime = createRuntime(
    {
      call: async (method, params) => {
        if (method === "summarize") {
          prompts.push(String(params?.prompt));
          return { title: "Título", summary: "Resumen breve", tags: [] };
        }
        return m.host.call(method, params);
      },
    },
    { run: async () => null },
  );
  await runtime.summarizeRecording("r", "local-llm");
  assert.equal(prompts.length, 3);
  assert.ok(prompts[0].length <= 3500);
  assert.match(prompts[2], /Integra estos resúmenes/);
});
test("recuperación recuerda preguntas y resumen ya calculados sin repetir peticiones al modelo", async () => {
  const m = memory();
  const cache = new Map<string, unknown>();
  let asks = 0;
  let summaries = 0;
  let fail = true;
  const host: RuntimeHost = {
    call: async (method, params = {}) => {
      const key = String(params.fingerprint);
      if (method === "memory_recall") return cache.get(key) ?? null;
      if (method === "memory_keep") {
        cache.set(key, params.value);
        return null;
      }
      if (method === "ask") {
        asks++;
        return "respuesta recordada";
      }
      if (method === "summarize") {
        summaries++;
        return { title: "Título", summary: "Resumen", tags: [] };
      }
      if (method === "version_update" && params.digest && fail) {
        fail = false;
        throw Error("cierre después de inferencia");
      }
      return m.host.call(method, params);
    },
  };
  const recipe: RuntimeRunner = {
    run: async (_, context) => {
      await context.call("transcribe", {});
      await context.call("ask", { entrada: "Pregunta" });
      await context.call("summarize", {});
      await context.call("save", {});
      return null;
    },
  };
  await assert.rejects(
    createRuntime(host, recipe).processRecording("r", { force: false }),
    /cierre después/,
  );
  await createRuntime(host, recipe).processRecording("r", { force: false });
  assert.equal(asks, 1);
  assert.equal(summaries, 1);
  assert.equal(m.state.recordings[0].versions.length, 1);
  assert.equal(m.state.recordings[0].versions[0].digest?.summary, "Resumen");
});
test("prueba de receta conserva traza y resultado sin escribir versión ni memoria", async () => {
  const m = memory();
  const runtime = createRuntime(m.host, {
    run: async (_, context) => {
      await context.call("transcribe", {});
      await context.call("save", { data: { tema: "Prueba" } });
      return null;
    },
  });
  await runtime.processRecording("r", { dryRun: true });
  assert.equal(m.state.recordings[0].versions.length, 0);
  assert.ok(
    !m.calls.some(
      (c) => c.method === "memory_keep" || c.method === "version_save",
    ),
  );
  const trace = m.calls.find((c) => c.method === "trace_save")?.params;
  assert.equal(trace?.dryRun, true);
  assert.deepEqual(
    (trace?.steps as { capability: string }[]).map((s) => s.capability),
    ["transcribe", "save"],
  );
  assert.deepEqual((trace?.result as { data: unknown }).data, {
    tema: "Prueba",
  });
});
test("respuesta que incumple esquema no contamina memoria para el reintento", async () => {
  const m = memory();
  const cache = new Map<string, unknown>();
  let count = 0;
  const host: RuntimeHost = {
    call: async (method, params = {}) => {
      if (method === "memory_recall")
        return cache.get(String(params.fingerprint)) ?? null;
      if (method === "memory_keep") {
        cache.set(String(params.fingerprint), params.value);
        return null;
      }
      if (method === "ask") {
        count++;
        return count === 1 ? { answer: 10 } : { answer: "correcto" };
      }
      return m.host.call(method, params);
    },
  };
  const recipe: RuntimeRunner = {
    run: async (_, context) => {
      await context.call("transcribe", {});
      await context.call("ask", {
        entrada: "Pregunta",
        schema: {
          type: "object",
          properties: { answer: { type: "string" } },
          required: ["answer"],
        },
      });
      return null;
    },
  };
  await assert.rejects(
    createRuntime(host, recipe).processRecording("r", { force: false }),
  );
  assert.equal(cache.size, 0);
  await createRuntime(host, recipe).processRecording("r", { force: false });
  assert.equal(count, 2);
  assert.equal(cache.size, 1);
});
test("audio modificado bajo el mismo ID invalida reuso automático", async () => {
  const m = memory();
  Object.assign(m.state.recordings[0], { audioHash: "audio-first" });
  const runtime = createRuntime(m.host, {
    run: async (_, context) => {
      await context.call("transcribe", {});
      await context.call("save", {});
      return null;
    },
  });
  await runtime.processRecording("r", { force: false });
  await runtime.processRecording("r", { force: false });
  assert.equal(
    m.calls.filter((call) => call.method === "transcribe").length,
    1,
  );
  Object.assign(m.state.recordings[0], { audioHash: "audio-changed" });
  await runtime.processRecording("r", { force: false });
  assert.equal(
    m.calls.filter((call) => call.method === "transcribe").length,
    2,
  );
  assert.equal(m.state.recordings[0].versions.length, 2);
  assert.equal(
    m.state.recordings[0].versions.at(-1)?.inputs?.audioHash,
    "audio-changed",
  );
});
