import { test } from "node:test";
import assert from "node:assert/strict";
import type { Host, Receipt } from "../src/types.js";
import { run } from "../src/index.js";
const note = {
  key: "llamada",
  startedAt: "2025-09-16T09:00:00Z",
  text: "Hola.\nDime.",
  segments: [
    { start: 0, end: 12, speaker: "Ruben", text: "Hola." },
    { start: 12, end: 187, speaker: "Aritz", text: "Dime." },
  ],
  digest: {
    title: "Backups de cortes",
    summary: "Se revisa el restore. Luego se habla de MinIO.",
    tags: ["backups", "Talos Linux"],
  },
  source: "file:///Notas/llamada.m4a",
  timeZone: "Europe/Madrid",
};
const now = "2026-10-05T17:00:00Z";
function folder(initial: Record<string, string> = {}): {
  files: Record<string, string>;
  receipts: Receipt[];
  host: Host;
} {
  const files = { ...initial };
  const receipts: Receipt[] = [];
  return {
    files,
    receipts,
    host: {
      files: {
        snapshot: async () => ({ ...files }),
        apply: async (changes: { path: string; contents: string | null }[]) => {
          for (const c of changes) {
            if (c.contents === null) delete files[c.path];
            else files[c.path] = c.contents;
          }
        },
      },
      checkpoint: async (r: Receipt) => {
        receipts.push(structuredClone(r));
      },
      audio: async () => null,
      fetch: async () => {
        throw Error("Unexpected HTTP");
      },
    },
  };
}
test("publica N documentos OKF con tipos YAML y enlaces cruzados", async () => {
  const f = folder();
  const result = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle", producer: "escriba/1.0" },
      note,
      now,
    },
    f.host,
  );
  assert.equal(result.locator, "notas/2025-09-16-backups-de-cortes.md");
  const content = f.files[result.locator!];
  assert.match(content, /recorded_at: 2025-09-16T11:00:00\+02:00/);
  assert.match(content, /tags: \[backups, talos-linux\]/);
  assert.match(content, /duration: 187/);
  assert.match(
    content,
    /\[Transcripción: Backups de cortes\]\(\/transcripciones\/2025-09-16-backups-de-cortes.md\)/,
  );
  assert.equal(f.receipts.length, 2);
});
export { note, now, folder };
test("retira todas las rutas del recibo y protege cambios ajenos", async () => {
  const f = folder();
  const published = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      now,
    },
    f.host,
  );
  f.files[published.locator!] += "\nEdición manual";
  await assert.rejects(
    () =>
      run(
        {
          operation: "remove",
          provider: "okf",
          config: { folder: "/bundle" },
          previous: published.receipt,
          now,
        },
        f.host,
      ),
    /cambió fuera/,
  );
});
test("Notion guarda localizador antes del segundo lote y reescribe conservando enlace", async () => {
  const calls: { path: string; body: { children?: unknown[] } }[] = [];
  const f = folder();
  f.host.fetch = async (input, init) => {
    const path = String(input);
    calls.push({
      path,
      body: init?.body ? JSON.parse(String(init.body)) : null,
    });
    if (path.endsWith("/pages"))
      return new Response(
        JSON.stringify({ id: "page-1", url: "https://notion.so/page-1" }),
      );
    if (path.includes("/children") && init?.method === "GET")
      return new Response(JSON.stringify({ results: [], has_more: false }));
    return new Response("{}");
  };
  const config = {
    source: {
      id: "source-1",
      title: "Notas",
      databaseTitle: "Notas",
      properties: [{ name: "Nombre", type: "title" }],
    },
    columns: { Nombre: "{{titulo}}" },
    body: "{{transcripcion}}",
  };
  const long = {
    ...note,
    segments: Array.from({ length: 205 }, (_, i) => ({
      start: i,
      end: i + 1,
      speaker: String(i),
      text: "hola",
    })),
  };
  const first = await run(
    { operation: "publish", provider: "notion", config, note: long, now },
    f.host,
  );
  assert.equal(first.locator, "page-1");
  assert.equal(calls[0].body.children?.length, 100);
  assert.equal(calls[1].body.children?.length, 100);
  assert.equal(calls[2].body.children?.length, 5);
  assert.equal(f.receipts.find((r) => r.locator)?.locator, "page-1");
  calls.length = 0;
  const next = await run(
    {
      operation: "publish",
      provider: "notion",
      config,
      note: { ...note, digest: null },
      previous: first.receipt,
      now,
    },
    f.host,
  );
  assert.equal(next.locator, first.locator);
  assert.ok(!calls.some((c) => c.path.endsWith("/pages")));
});
test("migración conserva UUID y referencias de documentos y convierte mapeo antiguo", async () => {
  const migrated = await run({
    operation: "migrate",
    provider: "notion",
    config: {
      source: {
        id: "s",
        title: "Notas",
        properties: [
          { name: "Título", type: "title" },
          { name: "Segundos", type: "number" },
        ],
      },
      mapping: { byField: { title: "Título", duration: "Segundos" } },
      template: {
        blocks: [
          { heading: { _0: "Texto" } },
          { transcript: { _0: "timestamps" } },
        ],
      },
    },
  });
  assert.deepEqual(migrated.configuration, {
    source: {
      id: "s",
      title: "Notas",
      databaseTitle: "",
      properties: [
        { name: "Título", type: "title" },
        { name: "Segundos", type: "number" },
      ],
    },
    columns: { Título: "{{titulo}}", Segundos: "{{segundos}}" },
    body: "# Texto\n\n{{transcripcion-tiempos}}",
  });
  const doc = {
    id: "uuid-original",
    name: "Acta",
    path: "docs/{{clave}}.md",
    properties: [{ id: "p", key: "type", value: "Acta" }],
    body: "{{enlace:uuid-original}}",
  };
  const okf = await run({
    operation: "migrate",
    provider: "okf",
    config: { folder: "/bundle", documents: [doc] },
  });
  assert.deepEqual((okf.configuration as { documents: unknown[] }).documents, [
    doc,
  ]);
});
test("OKF reanuda un apply parcial desde el checkpoint sin duplicar rutas", async () => {
  const f = folder();
  let partial = true;
  const apply = f.host.files.apply;
  f.host.files.apply = async (changes) => {
    if (partial) {
      partial = false;
      await apply(changes.slice(0, 1));
      throw Error("disco lleno");
    }
    await apply(changes);
  };
  await assert.rejects(
    () =>
      run(
        {
          operation: "publish",
          provider: "okf",
          config: { folder: "/bundle" },
          note,
          now,
        },
        f.host,
      ),
    /disco lleno/,
  );
  const recovery = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      now,
      previous: f.receipts.at(-1),
    },
    f.host,
  );
  assert.equal(recovery.locator, "notas/2025-09-16-backups-de-cortes.md");
  assert.ok(!Object.keys(f.files).some((p) => p.includes("-2.md")));
  await run(
    {
      operation: "remove",
      provider: "okf",
      config: { folder: "/bundle" },
      previous: recovery.receipt,
      now,
    },
    f.host,
  );
  assert.deepEqual(Object.keys(f.files), ["log.md"]);
});
test("la creación Notion incierta no se reintenta y el 429 sí respeta Retry-After", async () => {
  const f = folder();
  let calls = 0;
  const config = {
    source: {
      id: "s",
      title: "Notas",
      properties: [{ name: "Nombre", type: "title" }],
    },
    columns: { Nombre: "{{titulo}}" },
  };
  f.host.fetch = async () => {
    calls++;
    return new Response(
      JSON.stringify({
        object: "error",
        status: 500,
        code: "internal_server_error",
        message: "incierto",
      }),
      { status: 500 },
    );
  };
  await assert.rejects(() =>
    run(
      { operation: "publish", provider: "notion", config, note, now },
      f.host,
    ),
  );
  assert.equal(calls, 1);
  calls = 0;
  f.host.fetch = async () => {
    calls++;
    return calls === 1
      ? new Response(
          JSON.stringify({
            object: "error",
            status: 429,
            code: "rate_limited",
            message: "espera",
          }),
          { status: 429, headers: { "Retry-After": "0" } },
        )
      : new Response(JSON.stringify({ id: "p", url: "https://notion.so/p" }));
  };
  const result = await run(
    { operation: "publish", provider: "notion", config, note, now },
    f.host,
  );
  assert.equal(calls, 2);
  assert.equal(result.locator, "p");
});
test("destinos propios inspeccionan metadatos y validan input antes de publicar", async () => {
  const { defineOKFDestination, createProgram } = await import(
    "../src/index.js"
  );
  const { z } = await import("zod");
  const program = createProgram([
    defineOKFDestination({
      id: "actas",
      name: "Actas",
      account: "carpeta-1",
      configuration: { folder: "/bundle" },
      inputSchema: z.object({ key: z.string().min(1) }).passthrough(),
    }),
  ]);
  assert.equal(program.inspect().destinations[0].account, "carpeta-1");
  const f = folder();
  await assert.rejects(() =>
    program.run(
      {
        operation: "publish",
        destination: "actas",
        note: { ...note, key: "" },
        now,
      },
      f.host,
    ),
  );
  assert.equal(Object.keys(f.files).length, 0);
  const result = await program.run(
    { operation: "publish", destination: "actas", note, now },
    f.host,
  );
  assert.equal(result.locator, "notas/2025-09-16-backups-de-cortes.md");
});
test("preview sin nota muestra ejemplo y no escribe ficheros", async () => {
  const f = folder();
  const result = await run(
    {
      operation: "preview",
      provider: "okf",
      config: { folder: "/bundle" },
      now,
    },
    f.host,
  );
  assert.equal((result.files as unknown[]).length, 2);
  assert.equal(Object.keys(f.files).length, 0);
  assert.equal(f.receipts.length, 0);
});
test("Notion transforma tipos, limpia resumen eliminado y conserva estilos", async () => {
  const config = {
    source: {
      id: "s",
      title: "Notas",
      properties: [
        { name: "Título", type: "title" },
        { name: "Temas", type: "multi_select" },
        { name: "Resumen", type: "rich_text" },
        { name: "Duración", type: "number" },
        { name: "Fecha", type: "date" },
        { name: "Selección", type: "select" },
      ],
    },
    columns: {
      Título: "{{titulo}}",
      Temas: "{{etiquetas}}",
      Resumen: "{{resumen}}",
      Duración: "{{segundos}}",
      Fecha: "{{fecha-iso}}",
      Selección: "{{resumen}}",
    },
    body: "# Resumen\n{{resumen}}\n# Texto\n{{transcripcion-tiempos}}\n- **Fin**",
  };
  const preview = await run(
    {
      operation: "preview",
      provider: "notion",
      config,
      note: { ...note, digest: null },
      now,
    },
    folder().host,
  );
  assert.deepEqual((preview.properties as Record<string, unknown>).Resumen, {
    rich_text: [],
  });
  assert.deepEqual((preview.properties as Record<string, unknown>).Temas, {
    multi_select: [],
  });
  assert.deepEqual((preview.properties as Record<string, unknown>).Selección, {
    select: null,
  });
  assert.deepEqual((preview.properties as Record<string, unknown>).Duración, {
    number: 187,
  });
  const children = preview.children as {
    type: string;
    paragraph: {
      rich_text: {
        text: { content: string };
        annotations: { bold: boolean };
      }[];
    };
  }[];
  assert.deepEqual(
    children.map((c) => c.type),
    ["heading_1", "paragraph", "paragraph", "bulleted_list_item"],
  );
  assert.equal(
    children[1].paragraph.rich_text[0].text.content,
    "[00:00] Ruben: ",
  );
  assert.equal(children[1].paragraph.rich_text[0].annotations.bold, true);
});
test("SDK sube audio multipart y archiva página conocida", async () => {
  const f = folder();
  const paths: string[] = [];
  const parts: number[] = [];
  f.host.audio = async () => ({
    data: new Blob([new Uint8Array(21 * 1024 * 1024)], { type: "audio/mp4" }),
    filename: "nota.m4a",
  });
  f.host.fetch = async (input, init) => {
    const path = String(input);
    paths.push(path);
    if (init?.body instanceof FormData) {
      parts.push(Number(init.body.get("part_number")));
      assert.equal((init.body.get("file") as File).type, "audio/mp4");
    }
    return new Response(
      JSON.stringify(
        path.endsWith("/file_uploads")
          ? { id: "upload-1" }
          : path.endsWith("/pages")
            ? { id: "page-1", url: "https://notion.so/p" }
            : {},
      ),
    );
  };
  const config = {
    source: {
      id: "s",
      title: "Notas",
      properties: [{ name: "Nombre", type: "title" }],
    },
    columns: { Nombre: "{{titulo}}" },
    body: "{{audio}}",
  };
  const result = await run(
    { operation: "publish", provider: "notion", config, note, now },
    f.host,
  );
  assert.deepEqual(parts, [1, 2, 3]);
  assert.ok(paths.at(-2)?.endsWith("/complete"));
  await run(
    {
      operation: "remove",
      provider: "notion",
      config,
      previous: result.receipt,
      now,
    },
    f.host,
  );
  assert.ok(paths.at(-1)?.endsWith("/pages/page-1"));
});
test("un cierre después de POST incierto exige reconciliar antes de crear otra página", async () => {
  const f = folder();
  let calls = 0;
  f.host.fetch = async () => {
    calls++;
    throw Error("conexión perdida");
  };
  const config = {
    source: {
      id: "s",
      title: "Notas",
      properties: [{ name: "Nombre", type: "title" }],
    },
    columns: { Nombre: "{{titulo}}" },
  };
  await assert.rejects(() =>
    run(
      { operation: "publish", provider: "notion", config, note, now },
      f.host,
    ),
  );
  const checkpoint = f.receipts.at(-1);
  assert.ok(checkpoint);
  await assert.rejects(
    () =>
      run(
        {
          operation: "publish",
          provider: "notion",
          config,
          note,
          now,
          previous: checkpoint,
        },
        f.host,
      ),
    /incierto/,
  );
  assert.equal(calls, 1);
});
test("rechaza recibos de otra nota o rutas fuera del bundle antes de aplicar", async () => {
  const f = folder();
  const config = { folder: "/bundle" };
  await assert.rejects(() =>
    run(
      {
        operation: "publish",
        provider: "okf",
        config,
        note,
        now,
        previous: {
          version: 1,
          provider: "okf",
          locator: "x",
          key: "otra",
          files: { "../ajeno.md": "hash" },
        },
      },
      f.host,
    ),
  );
  assert.equal(f.receipts.length, 0);
  assert.equal(Object.keys(f.files).length, 0);
});
test("Notion pagina todos los hijos antes de borrar y conserva ID remoto", async () => {
  const f = folder();
  const deleted: string[] = [];
  let pages = 0;
  f.host.fetch = async (input, init) => {
    const path = String(input);
    if (init?.method === "GET") {
      pages++;
      return new Response(
        JSON.stringify({
          results: [{ id: "b" + pages }],
          has_more: pages === 1,
          next_cursor: pages === 1 ? "cursor-2" : null,
        }),
      );
    }
    if (init?.method === "DELETE") deleted.push(path.split("/").at(-1)!);
    return new Response("{}");
  };
  const config = {
    source: {
      id: "s",
      title: "Notas",
      properties: [{ name: "Nombre", type: "title" }],
    },
    columns: { Nombre: "{{titulo}}" },
  };
  const result = await run(
    {
      operation: "publish",
      provider: "notion",
      config,
      note,
      now,
      previous: { locator: "page", url: "https://notion.so/page" },
    },
    f.host,
  );
  assert.equal(result.locator, "page");
  assert.deepEqual(deleted, ["b1", "b2"]);
  assert.equal(pages, 2);
});
test("texto literal que coincide con un marcador interno sigue siendo texto", async () => {
  const result = await run(
    {
      operation: "preview",
      provider: "notion",
      config: {
        source: {
          id: "s",
          title: "Notas",
          properties: [{ name: "Nombre", type: "title" }],
        },
        columns: { Nombre: "{{titulo}}" },
        body: "ESCRIBA_BLOCK_0\n{{transcripcion}}",
      },
      note,
    },
    folder().host,
  );
  const children = result.children as {
    type: string;
    paragraph: {
      rich_text: {
        text: { content: string };
        annotations: { bold: boolean };
      }[];
    };
  }[];
  assert.equal(children.length, 3);
  assert.equal(
    children[0].paragraph.rich_text[0].text.content,
    "ESCRIBA_BLOCK_0",
  );
});
test("validación OKF detecta rutas duplicadas y discovery describe los documentos", async () => {
  const doc = {
    id: "a",
    name: "Nota",
    path: "docs/x.md",
    properties: [{ key: "type", value: "Nota" }],
    body: "{{transcripcion}}",
  };
  const validation = await run({
    operation: "validate",
    provider: "okf",
    config: {
      folder: "/bundle",
      documents: [doc, { ...doc, id: "b", name: "Otra" }],
    },
  });
  assert.equal(validation.valid, false);
  const discovery = await run(
    {
      operation: "discover",
      provider: "okf",
      config: { folder: "/bundle", documents: [doc] },
    },
    folder().host,
  );
  assert.deepEqual(discovery.resources, [
    { id: "a", name: "Nota", description: "docs/x.md" },
  ]);
});
test("el documento y los índices conservan literalmente el formato Swift original", async () => {
  const f = folder();
  await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle", producer: "escriba/1.0" },
      note,
      now,
    },
    f.host,
  );
  assert.equal(
    f.files["notas/2025-09-16-backups-de-cortes.md"],
    '---\ntype: Nota de voz\ntitle: "Backups de cortes"\ndescription: "Se revisa el restore."\ntags: [backups, talos-linux]\nrecorded_at: 2025-09-16T11:00:00+02:00\nduration: 187\nspeakers: ["Ruben", "Aritz"]\nescriba_key: "llamada"\ngenerated: { by: "escriba/1.0", at: 2026-10-05T17:00:00Z }\n---\n\n# Resumen\n\nSe revisa el restore. Luego se habla de MinIO.\n\n# Transcripción\n\n[Transcripción: Backups de cortes](/transcripciones/2025-09-16-backups-de-cortes.md)\n',
  );
  assert.equal(
    f.files["index.md"],
    "# Notas de voz\n\n* [notas](notas/) - Nota\n* [transcripciones](transcripciones/) - Transcripción\n",
  );
  assert.equal(
    f.files["notas/index.md"],
    "# Septiembre de 2025\n\n* [Backups de cortes](2025-09-16-backups-de-cortes.md) - Se revisa el restore.\n",
  );
  assert.equal(
    f.files["log.md"],
    "# Registro\n\n## 2026-10-05\n\n* **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)\n",
  );
});
