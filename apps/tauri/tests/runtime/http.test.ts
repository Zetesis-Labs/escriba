import { test } from "vitest";
import assert from "node:assert/strict";
import { createServer as createTcp, type Socket } from "node:net";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProviderAccess } from "@escriba/conectores";
import { authorizedAccess, httpWithGrant, parseOrigin, validateAccountGrant } from "../../src/runtime/http";

interface Listener {
  port: number;
  origin: string;
  requests: Promise<Buffer>[];
  close(): void;
}
function listen(reply: (request: Buffer) => string | Buffer, until: (data: Buffer) => boolean = (data) => data.includes("\r\n\r\n")): Promise<Listener> {
  return new Promise((resolve) => {
    const requests: Promise<Buffer>[] = [];
    const server = createTcp((socket: Socket) => {
      requests.push(
        new Promise<Buffer>((done) => {
          const chunks: Buffer[] = [];
          socket.on("data", (chunk) => {
            chunks.push(chunk);
            const data = Buffer.concat(chunks);
            if (until(data)) {
              socket.write(reply(data));
              socket.end();
              done(data);
            }
          });
        }),
      );
    });
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({ port, origin: `http://127.0.0.1:${port}`, requests, close: () => server.close() });
    });
  });
}
const complete = (data: Buffer) => {
  const head = data.indexOf("\r\n\r\n");
  if (head < 0) return false;
  const headers = data.subarray(0, head).toString().toLowerCase();
  const length = /content-length: (\d+)/.exec(headers);
  if (length) return data.length >= head + 4 + Number(length[1]);
  if (headers.includes("transfer-encoding: chunked")) return data.subarray(head).includes("\r\n0\r\n\r\n");
  return true;
};
const grantFor = (origin: string, credential: boolean): ProviderAccess => ({
  capability: "http",
  origin,
  allowedHeaders: ["accept", "content-type", "notion-version"],
  ...(credential ? { credential: { label: "Token", header: "authorization", prefix: "Bearer " } } : {}),
});

test("http inyecta el secreto solo hacia el origen autorizado y no sigue redirecciones", async () => {
  const other = await listen(() => "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
  const source = await listen(() => `HTTP/1.1 302 Found\r\nLocation: ${other.origin}/stolen\r\nContent-Length: 0\r\n\r\n`);
  try {
    const account = { enabled: true, origin: source.origin };
    const grant = grantFor(source.origin, true);
    const result = await httpWithGrant(account, grant, "test-secret", { url: `${source.origin}/notes`, headers: { accept: "application/json" } }, undefined);
    assert.equal(result.status, 302);
    const request = (await source.requests[0]!).toString().toLowerCase();
    assert.ok(request.includes("authorization: bearer test-secret"));
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(other.requests.length, 0);
    await assert.rejects(httpWithGrant(account, grant, "test-secret", { url: `${other.origin}/stolen` }, undefined), /fuera del origen/);
    await assert.rejects(httpWithGrant(account, grant, "test-secret", { url: `${source.origin}/notes`, headers: { Authorization: "attacker" } }, undefined), /Cabecera HTTP no permitida/);
    await assert.rejects(httpWithGrant(account, grant, "test-secret", { url: `http://@127.0.0.1:${source.port}/notes` }, undefined), /fuera del origen/);
    assert.throws(() => parseOrigin("http://localhost:1234"), /no permitido/);
  } finally {
    source.close();
    other.close();
  }
});

test("una autorización propia inyecta su cabecera y rechaza una autorización caducada", async () => {
  const server = await listen(() => "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", complete);
  try {
    const grant = { capability: "http", origin: server.origin, allowedHeaders: ["x-version"], credential: { label: "Token", header: "x-api-key", prefix: "Key " } };
    const provider = { id: "example", ...grant };
    const account = { id: "a", provider: "example", enabled: true, grant };
    const request = { url: `${server.origin}/items`, headers: { "x-version": "2026" }, expectedGrant: grant };
    const accepted = authorizedAccess(account, provider, request, "http");
    const result = await httpWithGrant(account, accepted, "synthetic", request, undefined);
    assert.equal(result.status, 200);
    const sent = (await server.requests[0]!).toString().toLowerCase();
    assert.ok(sent.includes("x-api-key: key synthetic"));
    assert.ok(sent.includes("x-version: 2026"));
    const changed = { ...provider, origin: "https://changed.example" };
    assert.throws(() => authorizedAccess(account, changed, request, "http"), /proveedor cambió/);
    assert.throws(() => authorizedAccess({ ...account, enabled: false }, provider, request, "http"), /desactivada/);
  } finally {
    server.close();
  }
});

test("una cuenta Notion antigua acepta el mismo permiso con otra etiqueta", () => {
  const account = { id: "old", provider: "notion", origin: "https://api.notion.com", enabled: true };
  const expected = { capability: "http", origin: "https://api.notion.com/", allowedHeaders: ["notion-version", "Content-Type", "accept"], credential: { label: "Token de la integración", header: "Authorization", prefix: "Bearer " } };
  assert.equal(authorizedAccess(account, undefined, { expectedGrant: expected }, "http").origin, "https://api.notion.com");
  const changed = { capability: "http", origin: "https://other.example", allowedHeaders: ["accept", "content-type", "notion-version"], credential: { label: "Token", header: "authorization", prefix: "Bearer " } };
  assert.throws(() => authorizedAccess(account, undefined, { expectedGrant: changed }, "http"), /cambió/);
  const disclosed = { capability: "http", origin: "https://api.notion.com", allowedHeaders: [], credential: { label: "Token", header: "authorization", value: "synthetic-secret" } };
  assert.throws(() => validateAccountGrant(disclosed), /no permitidos/);
  assert.throws(() => validateAccountGrant({ capability: "http", origin: "https://api.notion.com", allowedHeaders: ["x-api-key"], credential: { label: "T", header: "x-api-key" } }), /no puede pasar desde la receta/);
});

test("multipart envía solo el rango de audio autorizado", async () => {
  const folder = await mkdtemp(join(tmpdir(), "escriba-http-"));
  const path = join(folder, "sample.wav");
  await writeFile(path, "0123456789");
  const server = await listen(() => "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", complete);
  try {
    const account = { enabled: true, origin: server.origin };
    const request = {
      url: `${server.origin}/upload`,
      method: "POST",
      multipart: [{ name: "file", audio: { recordingId: "r1", start: 2, end: 6 }, filename: "sample.wav", type: "audio/wav" }],
    };
    const result = await httpWithGrant(account, grantFor(server.origin, false), undefined, request, { path, recordingId: "r1" });
    assert.equal(result.status, 200);
    const sent = (await server.requests[0]!).toString("latin1");
    assert.ok(sent.includes("2345"));
    assert.ok(!sent.includes("0123456789"));
    assert.ok(sent.toLowerCase().includes('filename="sample.wav"'));
    await assert.rejects(httpWithGrant(account, grantFor(server.origin, false), undefined, { ...request, multipart: [{ name: "file", audio: { recordingId: "other" } }] }, { path, recordingId: "r1" }), /no autorizado/);
    await assert.rejects(httpWithGrant(account, grantFor(server.origin, false), undefined, { ...request, multipart: [{ name: "file", audio: { recordingId: "r1", start: 8, end: 4 } }] }, { path, recordingId: "r1" }), /Rango de audio/);
  } finally {
    server.close();
    await rm(folder, { recursive: true, force: true });
  }
});
