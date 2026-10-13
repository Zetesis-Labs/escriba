import { afterAll, beforeAll, test } from "vitest";
import assert from "node:assert/strict";
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { controllerEnvironment } from "./native";

let directory = "";
let executable = "";
beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "escriba-protocol-"));
  executable = join(directory, "runtime");
  const build = fileURLToPath(new URL("../../runtime-host/build.mjs", import.meta.url));
  const result = spawnSync(process.execPath, [build, executable], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
}, 60000);
afterAll(async () => {
  await rm(directory, { recursive: true, force: true });
});

interface Frame extends Record<string, unknown> {
  type: string;
  id?: string;
}
function controller() {
  const child: ChildProcessWithoutNullStreams = spawn(executable, [], {
    env: controllerEnvironment(directory),
    cwd: "/",
  });
  const frames: Frame[] = [];
  const waiters: ((frame: Frame) => void)[] = [];
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  createInterface({ input: child.stdout }).on("line", (line) => {
    const frame = JSON.parse(line) as Frame;
    if (frame.type === "call" || frame.type === "event") return;
    const waiter = waiters.shift();
    if (waiter) waiter(frame);
    else frames.push(frame);
  });
  const next = () =>
    new Promise<Frame>((resolve, reject) => {
      const queued = frames.shift();
      if (queued) return resolve(queued);
      const timer = setTimeout(() => reject(Error(`Sin trama: ${stderr}`)), 10000);
      waiters.push((frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
    });
  const send = (value: unknown) => child.stdin.write(`${JSON.stringify(value)}\n`);
  return {
    next,
    send,
    async command(id: string, method: string, params: unknown = {}, origin: unknown = "ui") {
      send({ type: "command", id, method, params, origin });
      const reply = await next();
      assert.equal(reply.id, id);
      return reply;
    },
    close() {
      child.kill("SIGKILL");
    },
  };
}

test("el controlador anuncia el protocolo y responde a un comando propio", async () => {
  const host = controller();
  try {
    const ready = await host.next();
    assert.equal(ready.type, "ready");
    assert.equal(ready.protocolVersion, 1);
    const reply = await host.command("c1", "controller_status");
    assert.equal(reply.type, "result");
    assert.deepEqual(reply.value, { protocolVersion: 1, dataPath: directory });
  } finally {
    host.close();
  }
});

test("un método que no es del controlador falla nombrándolo, sin cerrar el canal", async () => {
  const host = controller();
  try {
    await host.next();
    const unknown = await host.command("c1", "inventado");
    assert.equal(unknown.type, "error");
    assert.equal(unknown.message, "Método desconocido: inventado");
    const origin = await host.command("c2", "controller_status", {}, "recipe");
    assert.equal(origin.type, "error");
    assert.equal(origin.message, "Origen del comando no permitido");
    const repeated = await host.command("c3", "controller_status");
    assert.equal(repeated.type, "result");
  } finally {
    host.close();
  }
});

test("un id de comando repetido se rechaza mientras el primero sigue vivo", async () => {
  const host = controller();
  try {
    await host.next();
    host.send({ type: "command", id: "same", method: "controller_status", params: {}, origin: "ui" });
    host.send({ type: "command", id: "same", method: "controller_status", params: {}, origin: "ui" });
    const replies = [await host.next(), await host.next()];
    const types = replies.map((reply) => reply.type).sort();
    assert.deepEqual(types, ["error", "result"]);
    const error = replies.find((reply) => reply.type === "error");
    assert.equal(error?.message, "ID de ejecución repetido");
  } finally {
    host.close();
  }
});
