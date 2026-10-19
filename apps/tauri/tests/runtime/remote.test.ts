import { test } from "vitest";
import assert from "node:assert/strict";
import { devNull } from "node:os";
import { createServer, type Server } from "node:net";
import { RuntimeError } from "../../src/runtime/contracts";
import { ask, digestSchema, endpoint, models, privateHost, readResponse, silentWav, transcribe } from "../../src/runtime/remote";

function rawServer(status: string, body: string, declaredLength: number): Promise<{ port: number; close(): void }> {
  return new Promise((resolve) => {
    const server: Server = createServer((socket) => {
      socket.once("data", () => {
        socket.write(`HTTP/1.1 ${status}\r\nContent-Length: ${declaredLength}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n${body}`);
        socket.end();
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({ port: typeof address === "object" && address ? address.port : 0, close: () => server.close() });
    });
  });
}

test("respuesta cortada se reintenta y errores 400 no", async () => {
  const code = async (status: string, body: string, declared: number) => {
    const server = await rawServer(status, body, declared);
    try {
      const response = await fetch(`http://127.0.0.1:${server.port}/test`);
      await readResponse(response, undefined);
      return "ok";
    } catch (error) {
      assert.ok(error instanceof RuntimeError, String(error));
      return error.code;
    } finally {
      server.close();
    }
  };
  assert.equal(await code("200 OK", '{"partial":', 100), "backend_unavailable");
  assert.equal(await code("401 Unauthorized", "{}", 2), "backend_unavailable");
  assert.equal(await code("429 Too Many Requests", "{}", 2), "backend_unavailable");
  assert.equal(await code("400 Bad Request", "{}", 2), "failed");
  assert.equal(await code("200 OK", '{"data":[]}', 11), "ok");
});

test("http solo vale dentro de tu red como en Swift", () => {
  for (const host of ["localhost", "mac.local", "127.0.0.1", "10.0.0.4", "192.168.1.20", "172.20.0.1", "100.101.102.103", "::1", "fd7a:115c::1"])
    assert.ok(privateHost(host), host);
  for (const host of ["example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "fdroid.org"])
    assert.ok(!privateHost(host), host);
  assert.ok(endpoint({ url: "http://192.168.1.20:1234/v1" }, "models"));
  assert.throws(() => endpoint({ url: "http://api.example.com/v1" }, "models"), /https:\/\//);
  assert.equal(endpoint({ url: "https://api.openai.com/v1/" }, "models").href, "https://api.openai.com/v1/models");
  assert.throws(() => endpoint({ url: "https://user:pw@api.openai.com/v1" }, "models"), /usuario ni contraseña/);
});

test("el audio de prueba es un segundo de silencio en wav", () => {
  const wav = silentWav();
  assert.equal(wav.length, 44 + 32_000);
  assert.equal(new TextDecoder().decode(wav.slice(0, 4)), "RIFF");
  assert.equal(new TextDecoder().decode(wav.slice(8, 12)), "WAVE");
  assert.ok(wav.slice(44).every((byte) => byte === 0));
});

test("los modelos llegan ordenados y sin repetir, con el secreto como Bearer y nunca en el error", async () => {
  const seen: Request[] = [];
  const transport = async (request: Request) => {
    seen.push(request);
    if (request.url.endsWith("/models"))
      return new Response(JSON.stringify({ data: [{ id: "b" }, { id: "a" }, { id: "b" }] }), { status: 200 });
    return new Response("llave secreta-xyz filtrada", { status: 500 });
  };
  const resolver = { url: "https://api.example.com/v1", model: "m" };
  assert.deepEqual(await models(resolver, "secreta-xyz", transport), ["a", "b"]);
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer secreta-xyz");
  await assert.rejects(transcribe(resolver, "secreta-xyz", devNull, {}, transport), (error: unknown) => {
    assert.ok(error instanceof RuntimeError);
    assert.equal(error.code, "backend_unavailable");
    assert.ok(!error.message.includes("secreta-xyz"), error.message);
    assert.ok(error.message.includes("[credencial]"));
    return true;
  });
  await assert.rejects(transcribe(resolver, undefined, devNull, { diarize: true }, transport), /Whisper local/);
});

const SECRET = "secreta-xyz";
const resolver = { url: "https://api.example.com/v1", model: "m" };
const digest = { title: "T", summary: "S", tags: ["a"] };
function completion(content: string) {
  return new Response(JSON.stringify({ id: "x", object: "chat.completion", created: 1, model: "m", choices: [{ index: 0, finish_reason: "stop", message: { role: "assistant", content } }] }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
function answering(reply: () => Response | Promise<Response>) {
  const seen: { request: Request; body: Record<string, unknown> }[] = [];
  const transport = async (request: Request) => {
    seen.push({ request, body: JSON.parse(await request.clone().text()) });
    return reply();
  };
  return { seen, transport };
}
const asked = (schema?: unknown) => ({ instructions: "Resume la nota", prompt: "texto de la nota", ...(schema === undefined ? {} : { schema }) });
async function failure(promise: Promise<unknown>) {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof Error);
    assert.ok(!error.message.includes(SECRET), error.message);
    return { code: error instanceof RuntimeError ? error.code : "failed", message: error.message };
  }
  assert.fail("debía fallar");
}

test("una pregunta sin esquema devuelve el texto y llama a chat/completions con la clave como Bearer", async () => {
  const { seen, transport } = answering(() => completion("  respuesta  "));
  assert.equal(await ask(resolver, SECRET, asked(), transport), "  respuesta  ");
  const [{ request, body }] = seen as [(typeof seen)[number]];
  assert.equal(request.url, "https://api.example.com/v1/chat/completions");
  assert.equal(request.headers.get("authorization"), `Bearer ${SECRET}`);
  assert.equal(request.redirect, "manual");
  assert.equal(body.model, "m");
  assert.equal(body.temperature, 0.2);
  assert.equal(body.response_format, undefined);
  assert.deepEqual(body.messages, [
    { role: "system", content: "Resume la nota" },
    { role: "user", content: "texto de la nota" },
  ]);
});

test("con esquema se pide el esquema estricto y también se explica en las instrucciones", async () => {
  const { seen, transport } = answering(() => completion(JSON.stringify(digest)));
  assert.deepEqual(await ask(resolver, SECRET, asked(digestSchema()), transport), digest);
  const body = seen[0]!.body;
  const format = body.response_format as { type: string; json_schema: { schema: unknown; strict: boolean } };
  assert.equal(format.type, "json_schema");
  assert.equal(format.json_schema.strict, true);
  assert.deepEqual(format.json_schema.schema, digestSchema());
  const system = (body.messages as { role: string; content: string }[]).filter((message) => message.role === "system").map((message) => message.content).join("\n");
  assert.ok(system.includes("Resume la nota"), system);
  assert.ok(system.includes('"summary"'), system);
});

test("un modelo que ignora el formato y responde con un bloque de código o con texto alrededor también sirve", async () => {
  for (const content of ["```json\n" + JSON.stringify(digest) + "\n```", `Aquí tienes:\n${JSON.stringify(digest)}\nUn saludo.`]) {
    const { transport } = answering(() => completion(content));
    assert.deepEqual(await ask(resolver, SECRET, asked(digestSchema()), transport), digest, content);
  }
});

test("una respuesta que no cumple el esquema falla nombrando el campo", async () => {
  const { transport } = answering(() => completion(JSON.stringify({ title: "T", tags: [] })));
  const { code, message } = (await failure(ask(resolver, SECRET, asked(digestSchema()), transport)))!;
  assert.equal(code, "failed");
  assert.match(message, /esquema/);
  assert.match(message, /summary/);
});

test("una respuesta sin JSON o vacía falla sin reintentar", async () => {
  for (const content of ["No sé hacer JSON", ""]) {
    const { seen, transport } = answering(() => completion(content));
    const { code } = (await failure(ask(resolver, SECRET, asked(content ? digestSchema() : undefined), transport)))!;
    assert.equal(code, "failed", content);
    assert.equal(seen.length, 1);
  }
});

test("401, 403, 408, 429, 5xx y un corte de red se pueden reintentar; 400 no; la clave nunca aparece", async () => {
  for (const [status, expected] of [[401, "backend_unavailable"], [403, "backend_unavailable"], [408, "backend_unavailable"], [429, "backend_unavailable"], [500, "backend_unavailable"], [503, "backend_unavailable"], [400, "failed"]] as const) {
    const { seen, transport } = answering(() => new Response(JSON.stringify({ error: { message: `la clave ${SECRET} no vale` } }), { status, headers: { "content-type": "application/json" } }));
    const { code } = (await failure(ask(resolver, SECRET, asked(), transport)))!;
    assert.equal(code, expected, String(status));
    assert.equal(seen.length, 1, `sin reintentos internos en ${status}`);
  }
  const { code } = (await failure(ask(resolver, SECRET, asked(), async () => {
    throw new TypeError(`fetch failed hacia ${SECRET}`);
  })))!;
  assert.equal(code, "backend_unavailable");
});

test("http fuera de tu red se rechaza antes de llamar", async () => {
  const { seen, transport } = answering(() => completion("x"));
  await assert.rejects(ask({ url: "http://api.example.com/v1", model: "m" }, SECRET, asked(), transport), /https:\/\//);
  assert.equal(seen.length, 0);
});

test("una respuesta demasiado grande se corta", async () => {
  const chunk = new Uint8Array(1024 * 1024).fill(32);
  let sent = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent++ >= 40) controller.close();
      else controller.enqueue(chunk);
    },
  });
  const { code, message } = (await failure(ask(resolver, SECRET, asked(), async () => new Response(body, { status: 200, headers: { "content-type": "application/json" } }))))!;
  assert.equal(code, "failed");
  assert.match(message, /demasiado grande/);
  assert.ok(sent < 40, `leyó ${sent} MiB`);
});
