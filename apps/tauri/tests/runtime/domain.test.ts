import { afterEach, beforeEach, test } from "vitest";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { createCommands, registerControllerCommands, type CommandRegistry } from "../../src/runtime/commands";
import { object, RuntimeError, type RuntimeHost } from "../../src/runtime/contracts";
import type { Json } from "../../src/runtime/library/json";
import { memoryCredentials } from "../../src/runtime/credentials";
import { audioType, projectAccounts, registerDomainCommands, type Tasks } from "../../src/runtime/domain";
import { startLanes } from "../../src/runtime/lanes";
import { Library } from "../../src/runtime/library/library";
import { Queue } from "../../src/runtime/library/queue";
import { arr, obj, str } from "./library/fixture";

type Fixture = Awaited<ReturnType<typeof fixture>>;
let f: Fixture;
beforeEach(async () => {
  f = await fixture();
});
afterEach(async () => {
  await f.dispose();
});
async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), "escriba-domain-"));
  const library = await Library.open(dir);
  const queue = await Queue.open(library);
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const events: { event: string; value: unknown }[] = [];
  const logs: string[] = [];
  const executed: { operation: string; args: Record<string, unknown> }[] = [];
  const running = new Map<string, { abort: AbortController }>();
  const nativeHandlers = new Map<string, (params: Record<string, unknown>) => unknown>();
  let commands!: CommandRegistry;
  const host: RuntimeHost = {
    async call(method, params = {}) {
      calls.push({ method, params });
      if (commands.owns(method)) return commands.dispatch(method, params, "shell");
      if (method === "shell.native") {
        const request = object(params);
        const handler = nativeHandlers.get(String(request.method));
        if (handler) return handler(object(request.params ?? {}));
        if (request.method === "transcribe") return { text: "Hola desde Whisper", segments: [{ speaker: "Speaker 1", start: 0, end: 1, text: "Hola", words: [] }], voices: [{ speaker: "Speaker 1", model: "m", embedding: [1, 0] }] };
        if (request.method === "status") return { protocolVersion: 1, whisper: { available: true }, llm: { available: true } };
      }
      if (["shell.native_cancel", "shell.notify", "shell.autolaunch", "shell.validate_catalog"].includes(method)) return null;
      if (method === "shell.files") return { seen: params };
      throw Error(`Capacidad inesperada: ${method}`);
    },
  };
  let cancelled: (() => void) | undefined;
  let execute = async (operation: string, args: Record<string, unknown>): Promise<unknown> => {
    executed.push({ operation, args });
    return { versionId: "v-sintetica" };
  };
  const tasks: Tasks = {
    current: () => undefined,
    async run(id, _recording, body) {
      running.set(id, { abort: new AbortController() });
      try {
        return await body();
      } finally {
        running.delete(id);
      }
    },
    cancel(id) {
      running.get(id)?.abort.abort();
      cancelled?.();
    },
  };
  commands = createCommands();
  const requests: Request[] = [];
  const deps = {
    library,
    queue,
    host,
    credentials: memoryCredentials({ "remote-llm": "clave-llm", "remote-stt": "clave-stt" }),
    transport: async (request: Request) => {
      requests.push(request);
      const body = request.url.includes("transcriptions") ? { text: "texto remoto" } : { choices: [{ message: { content: "respuesta remota" } }] };
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    },
    tasks,
    execute: (operation: string, args: Record<string, unknown>) => execute(operation, args),
    notificationProblems: async () => [{ role: "llm", name: "Apple", reason: "Sin modelo" }],
    emit: (event: string, value?: unknown) => {
      events.push({ event, value });
    },
    log: (message: string) => {
      logs.push(message);
    },
  };
  registerControllerCommands(commands, { host, dataPath: dir, credentials: deps.credentials, audioPath: (recordingId) => library.audio(recordingId), emit: deps.emit });
  registerDomainCommands(commands, deps);
  const ui = (method: string, params: Record<string, unknown> = {}) => commands.dispatch(method, params, "ui");
  const shell = (method: string, params: Record<string, unknown> = {}) => commands.dispatch(method, params, "shell");
  const audio = (name: string, content = "audio sintetico") => {
    const path = join(dir, name);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, content);
    return path;
  };
  async function imported(name = "inbox/nota.wav", source = "/origen/nota.wav", content?: string) {
    const records = arr(await shell("import_inbox", { files: [{ inbox: audio(name, content), source }] }));
    return str(records[0]!.id);
  }
  return {
    dir,
    library,
    queue,
    deps,
    calls,
    requests,
    events,
    logs,
    executed,
    ui,
    shell,
    audio,
    imported,
    native(method: string, handler: (params: Record<string, unknown>) => unknown) {
      nativeHandlers.set(method, handler);
    },
    setExecute(next: typeof execute) {
      execute = next;
    },
    onCancel(handler: () => void) {
      cancelled = handler;
    },
    methods: () => calls.map((call) => call.method),
    async dispose() {
      await library.close().catch(() => undefined);
      await rm(dir, { recursive: true, force: true });
    },
  };
}
const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

test("cada origen solo alcanza sus comandos y ninguna respuesta lleva huellas", async () => {
  await assert.rejects(f.ui("settings_read"), /Origen no permitido para settings_read/);
  await assert.rejects(f.ui("people_add_voice", { name: "Ana", voice: { speaker: "S", model: "m", embedding: [1, 0] }, source: "muestra" }), /Origen no permitido/);
  await assert.rejects(f.shell("snapshot"), /Origen no permitido para snapshot/);
  await assert.rejects(f.shell("people_add_voice", { name: "Ana", voice: { speaker: "S" }, source: "muestra" }), /Huella de voz inválida/);
  assert.equal(await f.shell("people_add_voice", { name: "Ana", voice: { speaker: "S", model: "m", embedding: [1, 0] }, source: "muestra" }), null);
  const people = arr(await f.ui("people_list"));
  assert.equal(people[0]!.name, "Ana");
  assert.ok(!JSON.stringify(people).includes("embedding"));
  assert.deepEqual(f.events.map((event) => event.event), ["changed"]);
});

test("importar desde el buzón da de alta la nota, retira la copia y evita duplicados", async () => {
  const inbox = f.audio("inbox/nota.wav");
  const [record] = arr(await f.shell("import_inbox", { files: [{ inbox, source: "/origen/nota.wav" }], recipeId: "default" }));
  assert.ok(!existsSync(inbox));
  assert.equal(record!.source, "/origen/nota.wav");
  assert.equal(f.library.index().recordings.length, 1);
  const again = f.audio("inbox/otra.wav");
  const [same] = arr(await f.shell("import_inbox", { files: [{ inbox: again, source: "/origen/otra.wav" }] }));
  assert.equal(same!.id, record!.id);
  assert.ok(!existsSync(again));
  assert.equal(obj(await f.ui("recording_detail", { id: str(record!.id) })).id, record!.id);
  assert.deepEqual(obj(await f.ui("snapshot")).recordings, [record]);
});

test("runtime_run ejecuta en línea las operaciones ligeras y encola las duraderas hasta su resultado", async () => {
  assert.deepEqual(await f.ui("runtime_run", { operation: "getRecipeSchema", args: { recipeId: "default" } }), { versionId: "v-sintetica" });
  assert.deepEqual(f.executed, [{ operation: "getRecipeSchema", args: { recipeId: "default" } }]);
  const id = await f.imported();
  const stop = startLanes(f.deps);
  try {
    for (let attempt = 0; attempt < 100 && f.executed.length < 2; attempt++) await settle();
    assert.equal(f.executed[1]?.operation, "processRecording", "la nota pendiente se procesa sola al arrancar los carriles");
    for (let attempt = 0; attempt < 100 && arr(await f.ui("runtime_jobs")).length; attempt++) await settle();
    assert.deepEqual(await f.ui("runtime_run", { operation: "processRecording", args: { recordingId: id, options: { force: true } } }), { versionId: "v-sintetica" });
  } finally {
    stop();
  }
  assert.equal(f.executed.length, 3);
  assert.deepEqual(arr(await f.ui("runtime_jobs")), []);
  const history = obj(await f.ui("runtime_history", { limit: 10 }));
  assert.deepEqual(arr(history.jobs).map((job) => job.state), ["succeeded", "succeeded"]);
  assert.ok(!f.methods().includes("shell.notify"), "sin versión creada no hay aviso");
});

test("un trabajo automático que falla por motor caído notifica, y cancelar aborta el trabajo y la inferencia", async () => {
  const id = await f.imported();
  f.setExecute(async () => {
    throw new RuntimeError("Sin conexión", "backend_unavailable");
  });
  await f.ui("settings_save", { settings: { notifyEveryNote: true } });
  let stop = startLanes(f.deps);
  for (let attempt = 0; attempt < 100 && !f.methods().includes("shell.notify"); attempt++) await settle();
  stop();
  const notice = f.calls.find((call) => call.method === "shell.notify");
  assert.equal(notice?.params.title, "El motor de transcripción no responde");
  assert.equal(notice?.params.body, "Sin conexión");
  f.setExecute(
    () =>
      new Promise((_, reject) => {
        f.onCancel(() => reject(new DOMException("Proceso cancelado", "AbortError")));
      }),
  );
  const second = await f.imported("inbox/segunda.wav", "/origen/segunda.wav", "otro audio sintetico");
  stop = startLanes(f.deps);
  for (let attempt = 0; attempt < 100 && !arr(await f.ui("runtime_jobs")).some((job) => job.recordingId === second && job.state === "running"); attempt++) await settle();
  assert.equal(await f.ui("runtime_cancel", { recordingId: second }), null);
  for (let attempt = 0; attempt < 100 && arr(await f.ui("runtime_jobs")).some((job) => job.recordingId === second); attempt++) await settle();
  stop();
  assert.ok(f.methods().includes("shell.native_cancel"));
  const states = arr(obj(await f.ui("runtime_history", { limit: 10 })).jobs).map((job) => job.state);
  assert.ok(states.includes("cancelled"), states.join(","));
});

test("guardar ajustes sincroniza el inicio automático, avisa a la vigilancia y revisa los resolutores", async () => {
  await f.ui("settings_save", { settings: { launchAtLogin: true, watchedFolders: [] } });
  assert.deepEqual(f.calls[0], { method: "shell.autolaunch", params: { enabled: true } });
  assert.deepEqual(f.events.map((event) => event.event), ["settings", "changed"]);
  assert.equal(obj(await f.shell("settings_read")).launchAtLogin, true);
  for (let attempt = 0; attempt < 50 && !f.methods().includes("shell.notify"); attempt++) await settle();
  assert.equal(f.calls.find((call) => call.method === "shell.notify")?.params.title, "No se puede resumir con Apple");
  assert.deepEqual(f.logs, ["Sin modelo"]);
});

test("la inferencia local pasa por la cáscara con la ruta del audio y reconoce la transcripción", async () => {
  const id = await f.imported();
  const transcript = obj(await f.ui("transcribe", { recordingId: id, resolverId: "local-stt", language: "es", diarize: true }));
  assert.equal(transcript.text, "Hola desde Whisper");
  assert.ok(!JSON.stringify(transcript).includes("embedding"));
  const native = f.calls.find((call) => call.method === "shell.native");
  assert.equal(native?.params.method, "transcribe");
  assert.equal(object(native?.params.params).audioPath, f.library.audio(id));
  await assert.rejects(f.ui("transcribe", { recordingId: id, resolverId: "inexistente" }), /No existe inexistente en resolvers/);
  await assert.rejects(f.ui("ask", { resolverId: "remote-llm", prompt: "x" }), /No existe remote-llm en resolvers/);
});

test("cada Whisper local transcribe con su modelo y el de serie con el de los ajustes", async () => {
  const id = await f.imported();
  await f.ui("config_save", { collection: "resolvers", item: { id: "local-stt-base", name: "Whisper · base", role: "stt", model: "base" } });
  await f.ui("transcribe", { recordingId: id, resolverId: "local-stt-base", language: "es" });
  await f.ui("transcribe", { recordingId: id, resolverId: "local-stt", language: "es" });
  const models = f.calls
    .filter((call) => call.method === "shell.native" && object(call.params).method === "transcribe")
    .map((call) => object(object(call.params).params).model);
  assert.deepEqual(models, ["base", obj(await f.shell("settings_read")).whisperModel]);
});

test("sin STT elegido transcribe el primer Whisper local que queda, y sin ninguno espera", async () => {
  const id = await f.imported();
  await f.ui("config_save", { collection: "resolvers", item: { id: "local-stt-base", name: "Whisper · base", role: "stt", model: "base" } });
  await f.ui("config_remove", { collection: "resolvers", id: "local-stt" });
  await f.ui("transcribe", { recordingId: id, language: "es" });
  const native = f.calls.filter((call) => call.method === "shell.native" && object(call.params).method === "transcribe").at(-1);
  assert.equal(object(object(native?.params).params).model, "base");
  await f.ui("config_remove", { collection: "resolvers", id: "local-stt-base" });
  await assert.rejects(f.ui("transcribe", { recordingId: id }), (error: Error & { code?: string }) => /ningún Whisper local/.test(error.message));
});

test("la inferencia remota lleva la clave guardada y nunca la devuelve", async () => {
  const id = await f.imported();
  await f.ui("config_save", { collection: "resolvers", item: { id: "remote-llm", name: "LLM", role: "llm", local: false, enabled: true, url: "https://llm.example/v1", model: "m" } });
  await f.ui("config_save", { collection: "resolvers", item: { id: "remote-stt", name: "STT", role: "stt", local: false, enabled: true, url: "https://stt.example/v1", model: "w" } });
  assert.equal(await f.ui("ask", { resolverId: "remote-llm", instructions: "i", prompt: "p" }), "respuesta remota");
  assert.equal(f.requests[0]?.headers.get("authorization"), "Bearer clave-llm");
  const transcript = obj(await f.ui("transcribe", { recordingId: id, resolverId: "remote-stt" }));
  assert.equal(transcript.text, "texto remoto");
  assert.equal(f.requests[1]?.headers.get("authorization"), "Bearer clave-stt");
  assert.ok(!f.calls.some((call) => call.method === "shell.native" && object(call.params).method !== "status"), "la inferencia remota no pasa por el motor local");
  await f.ui("config_save", { collection: "resolvers", item: { id: "remote-llm", name: "LLM", role: "llm", local: false, enabled: false, url: "https://llm.example/v1", model: "m" } });
  await assert.rejects(f.ui("ask", { resolverId: "remote-llm", prompt: "p" }), /El resolutor está apagado/);
});

test("una receta llama al modelo de un LLM remoto con su clave, y no al local ni a uno apagado", async () => {
  await f.ui("config_save", { collection: "resolvers", item: { id: "remote-llm", name: "LLM", role: "llm", local: false, enabled: true, url: "https://llm.example/v1", model: "m" } });
  const options = { prompt: [{ role: "user", content: [{ type: "text", text: "hola" }] }] };
  const result = obj(await f.ui("model_call", { resolverId: "remote-llm", method: "doGenerate", options }));
  assert.deepEqual(result.content, [{ type: "text", text: "respuesta remota" }]);
  assert.equal(f.requests.at(-1)?.headers.get("authorization"), "Bearer clave-llm");
  assert.ok(!JSON.stringify(result).includes("clave-llm"));
  await f.ui("config_save", { collection: "resolvers", item: { id: "local-llm", name: "Local", role: "llm", enabled: true } });
  await assert.rejects(f.ui("model_call", { resolverId: "local-llm", method: "doGenerate", options }), /LLM remoto/);
  await assert.rejects(f.ui("model_call", { resolverId: "local-stt", method: "doGenerate", options }), /no es un LLM/);
  await f.ui("config_save", { collection: "resolvers", item: { id: "remote-llm", name: "LLM", role: "llm", local: false, enabled: false, url: "https://llm.example/v1", model: "m" } });
  await assert.rejects(f.ui("model_call", { resolverId: "remote-llm", method: "doGenerate", options }), /apagado/);
});

test("el feed de conocimiento entrega lotes y acusa por clave y revisión", async () => {
  await f.imported();
  await f.shell("knowledge_feed_prepare", { epoch: "proyección-1" });
  const changes = arr(await f.shell("knowledge_feed_changes", { limit: 10 }));
  assert.ok(changes.length >= 1);
  assert.equal(changes[0]!.kind, "recording");
  await f.shell("knowledge_feed_ack", { acks: changes.map((change) => ({ key: change.key, revision: change.revision })) });
  assert.deepEqual(await f.shell("knowledge_feed_changes", { limit: 10 }), []);
  await assert.rejects(f.shell("knowledge_feed_changes", { limit: 0 }), /Límite de cambios inválido/);
});

test("el feed de conocimiento proyecta la nota y la persona sin rutas, secretos ni huellas", async () => {
  const id = await f.imported("inbox/privada.wav", "/origen/privada.wav");
  await f.shell("watch_folder_save", { path: f.dir, name: "Privada", style: "any", bookmark: [11, 22, 33] });
  await f.shell("people_add_voice", {
    name: "Ana sintética",
    voice: { speaker: "Speaker 1", model: "MODELO_PRIVADO", embedding: [0.25, 0.75] },
    source: "MUESTRA_PRIVADA",
  });
  await f.shell("version_save", {
    recordingId: id,
    backend: "sintético",
    transcript: {
      text: "Texto proyectado",
      language: "es",
      segments: [{ start: 0, end: 1, text: "Hola", speaker: "Speaker 1", words: [{ start: 0, end: 1, text: "Hola", secret: "PALABRA_PRIVADA" }], secret: "SEGMENTO_PRIVADO" }],
      secret: "TRANSCRIPCION_PRIVADA",
    },
    digest: { title: "Nota proyectada", summary: "Resumen proyectado", secret: "RESUMEN_PRIVADO" },
    inputs: { token: "TOKEN_PRIVADO" },
    data: { secret: "DATO_PRIVADO" },
  });
  await f.shell("knowledge_feed_prepare", { epoch: "proyección-privada" });
  const changes = arr(await f.shell("knowledge_feed_changes", { limit: 10 }));
  const recording = changes.find((change) => change.kind === "recording" && change.id === id);
  const person = changes.find((change) => change.kind === "person");
  assert.ok(recording);
  assert.ok(person);
  const snapshot = obj(recording.value);
  assert.equal(snapshot.id, id);
  assert.equal(arr(snapshot.versions).length, 1);
  const version = obj(arr(snapshot.versions)[0]);
  assert.equal(obj(version.transcript).text, "Texto proyectado");
  assert.equal(obj(version.digest).summary, "Resumen proyectado");
  assert.equal(obj(person.value).name, "Ana sintética");
  const projection = JSON.stringify(changes);
  for (const forbidden of [
    f.library.audio(id),
    "/origen/privada.wav",
    "accessBookmark",
    "11,22,33",
    "MODELO_PRIVADO",
    "MUESTRA_PRIVADA",
    "embedding",
    "0.25",
    "TOKEN_PRIVADO",
    "PALABRA_PRIVADA",
    "SEGMENTO_PRIVADO",
    "TRANSCRIPCION_PRIVADA",
    "RESUMEN_PRIVADO",
    "DATO_PRIVADO",
  ]) assert.ok(!projection.includes(forbidden), `El feed expuso ${forbidden}`);
});

test("las capturas de la grabadora se incorporan y se retiran, incluidas las recuperadas al arrancar", async () => {
  const capture = f.audio("captures/grabacion.m4a");
  const record = obj(await f.shell("recording_recorded", { path: capture, duration: 3, createdAt: "2026-10-13T10:00:00+00:00" }));
  assert.equal(record.duration, 3);
  assert.ok(!existsSync(capture));
  f.audio("captures/pendiente.m4a", "otra captura");
  f.audio("captures/vacia.m4a", "");
  assert.equal(await f.shell("captures_recover"), 1);
  assert.ok(existsSync(join(f.dir, "captures/vacia.m4a")), readdirSync(join(f.dir, "captures")).join(","));
  assert.ok(!existsSync(join(f.dir, "captures/pendiente.m4a")));
  const warnings = arr(await f.ui("log_list"))
    .filter((line) => line.level === "warn")
    .map((line) => line.message);
  assert.ok(warnings.includes("Recuperada una captura pendiente de guardar"), warnings.join("|"));
});

test("knowledge_context resuelve la receta base de un formulario y el estado de la nota", async () => {
  const id = await f.imported();
  await f.ui("config_save", { collection: "recipes", item: { id: "codigo", name: "Código", kind: "code", bundle: "export default {}", values: {} } });
  await f.ui("config_save", { collection: "recipes", item: { id: "form", name: "Formulario", kind: "form", base: "Código", values: {} } });
  const context = obj(await f.shell("knowledge_context", { recipeId: "form", recordingId: id }));
  assert.equal(obj(context.recipe).id, "codigo");
  assert.deepEqual(context.recording, { id, status: "pending" });
  await assert.rejects(f.shell("knowledge_context", { recipeId: "inexistente", recordingId: id }), /No existe inexistente en recipes/);
});

test("los archivos de conector exigen una cuenta autorizada antes de llegar a la cáscara", async () => {
  await assert.rejects(f.ui("connector_files", { accountId: "nadie", operation: "snapshot" }), /No existe nadie en accounts/);
  await f.ui("config_save", { collection: "accounts", item: { id: "okf-a", name: "OKF", provider: "okf", enabled: true, folder: f.dir } });
  const reply = obj(await f.ui("connector_files", { accountId: "okf-a", operation: "snapshot" }));
  assert.equal(obj(obj(reply.seen).account).id, "okf-a");
  await f.ui("config_save", { collection: "accounts", item: { id: "okf-a", name: "OKF", provider: "okf", enabled: false, folder: f.dir } });
  await assert.rejects(f.ui("connector_files", { accountId: "okf-a", operation: "snapshot" }), /Cuenta desactivada/);
});

test("el contexto del proyecto omite las cuentas cuyo destino nace en la app", () => {
  const accounts: Json[] = [
    { id: "app", name: "App", provider: "notion", enabled: true },
    { id: "code", name: "Code", provider: "okf", enabled: true },
  ];
  const destinations: Json[] = [
    { id: "app", account: "app", provider: "notion", configuration: {} },
    { id: "coded", account: "code", provider: "okf", program: "compiled" },
  ];
  assert.deepEqual(projectAccounts(accounts, destinations), [accounts[1]]);
  assert.equal(audioType("/x/nota.MP3"), "audio/mpeg");
  assert.equal(audioType("/x/nota.m4a"), "audio/mp4");
});

test("combinar une las copias en el orden dado, da de alta la combinada con sus piezas y descarta las originales", async () => {
  const first = await f.imported("inbox/primera.wav", "/origen/primera.wav", "audio uno");
  const second = await f.imported("inbox/segunda.wav", "/origen/segunda.wav", "audio dos");
  const copies = [f.library.audio(second), f.library.audio(first)];
  const native: Record<string, unknown>[] = [];
  f.native("combineAudio", (params) => {
    native.push(params);
    writeFileSync(str(params.outputPath), "audio combinado");
    return { duration: 7.5, parts: [{ start: 0, end: 3 }, { start: 4, end: 7.5 }] };
  });
  const record = obj(await f.ui("recording_combine", { ids: [second, first], keepOriginals: false }));
  const [request] = native;
  assert.deepEqual([arr(request!.inputs).map((input) => basename(str(input))), request!.gapSeconds], [copies.map((copy) => basename(copy)), 1]);
  assert.deepEqual([record.status, record.title, record.source, record.duration], ["pending", "Grabación combinada", "Combinación", 7.5]);
  assert.deepEqual(record.parts, [{ recordingId: second, title: "segunda", start: 0, end: 3 }, { recordingId: first, title: "primera", start: 4, end: 7.5 }]);
  const statuses = Object.fromEntries(arr((await f.library.snapshot()).recordings).map((item) => [obj(item).id, obj(item).status]));
  assert.deepEqual([statuses[first], statuses[second], statuses[str(record.id)]], ["discarded", "discarded", "pending"]);
  assert.ok(!existsSync(str(request!.outputPath)));
  await f.queue.automatic();
  const queued = arr(await f.queue.visible()).map((job) => obj(job));
  assert.ok(queued.some((job) => job.operation === "processRecording" && obj(job.args).recordingId === record.id), "la combinada entra en la cola como cualquier pendiente");
});

test("combinar se niega antes de unir si falta audio, y nombra la nota cuando el host no puede leer una pieza", async () => {
  const first = await f.imported("inbox/primera.wav", "/origen/primera.wav", "audio uno");
  const second = await f.imported("inbox/segunda.ogg", "/origen/segunda.ogg", "audio dos");
  await f.ui("recording_remove_audio", { id: first });
  let combined = 0;
  f.native("combineAudio", (params) => {
    combined++;
    throw new RuntimeError(`no se puede leer el audio: ${str(arr(params.inputs)[1])}`, "failed");
  });
  await assert.rejects(f.ui("recording_combine", { ids: [first, second] }), /«primera» no tiene copia de audio/);
  assert.equal(combined, 0);
  const third = await f.imported("inbox/tercera.wav", "/origen/tercera.wav", "audio tres");
  await assert.rejects(f.ui("recording_combine", { ids: [third, second] }), /No se puede leer el audio de «segunda» \(\.ogg\)/);
  const statuses = arr((await f.library.snapshot()).recordings).map((item) => obj(item).status);
  assert.ok(statuses.every((status) => status === "pending"));
});
