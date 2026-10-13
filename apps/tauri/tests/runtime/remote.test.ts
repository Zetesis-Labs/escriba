import { test } from "vitest";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:net";
import { RuntimeError } from "../../src/runtime/contracts";
import { endpoint, models, privateHost, readResponse, silentWav, transcribe } from "../../src/runtime/remote";

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
  await assert.rejects(transcribe(resolver, "secreta-xyz", "/dev/null", {}, transport), (error: unknown) => {
    assert.ok(error instanceof RuntimeError);
    assert.equal(error.code, "backend_unavailable");
    assert.ok(!error.message.includes("secreta-xyz"), error.message);
    assert.ok(error.message.includes("[credencial]"));
    return true;
  });
  await assert.rejects(transcribe(resolver, undefined, "/dev/null", { diarize: true }, transport), /Whisper local/);
});
