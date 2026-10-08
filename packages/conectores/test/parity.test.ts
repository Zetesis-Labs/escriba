import { test } from "node:test";
import assert from "node:assert/strict";
import { run } from "../src/index.js";
import type { Host, Note, Result, Receipt } from "../src/types.js";
const note: Note = {
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
function folder() {
  const files: Record<string, string> = {};
  const host: Host = {
    fetch: async () => {
      throw Error("HTTP inesperado");
    },
    files: {
      snapshot: async () => ({ ...files }),
      apply: async (changes) => {
        for (const c of changes)
          if (c.contents === null) delete files[c.path];
          else files[c.path] = c.contents;
      },
    },
    audio: async () => null,
    checkpoint: async () => {},
  };
  return { files, host };
}
const config = {
  source: {
    id: "s",
    title: "Notas",
    properties: [{ name: "Nombre", type: "title" }],
  },
  columns: { Nombre: "{{titulo}}" },
  body: "{{transcripcion}}",
};
type Preview = {
  properties: Record<string, unknown>;
  children: { type: string; [key: string]: unknown }[];
};
function preview(result: Result) {
  return result as unknown as Preview;
}
test("la sugerencia Notion respeta nombres, tipos, columnas manuales y vaciados explícitos", async () => {
  const source = {
    id: "s",
    title: "Notas",
    databaseTitle: "Notas",
    properties: [
      { name: "Nombre", type: "title" },
      { name: "Clave", type: "rich_text" },
      { name: "Libre", type: "rich_text" },
      { name: "Fecha de grabación", type: "date" },
      { name: "Duración", type: "number" },
    ],
  };
  const f = folder();
  f.host.fetch = async () =>
    new Response(
      JSON.stringify({
        results: [
          {
            ...source,
            object: "data_source",
            title: [{ plain_text: "Notas" }],
            properties: Object.fromEntries(
              source.properties.map((p) => [p.name, { type: p.type }]),
            ),
          },
        ],
        has_more: false,
      }),
    );
  const result = await run(
    { operation: "discover", provider: "notion", config: {} },
    f.host,
  );
  const first = (
    result.resources as { configuration: { columns: Record<string, string> } }[]
  )[0].configuration;
  assert.deepEqual(first.columns, {
    Nombre: "{{titulo}}",
    Clave: "{{clave}}",
    Libre: "{{hablantes}}",
    "Fecha de grabación": "{{fecha-iso}}",
    Duración: "{{segundos}}",
  });
  const second = await run(
    {
      operation: "discover",
      provider: "notion",
      config: { columns: { Nombre: "Manual", Clave: "", Borrada: "vieja" } },
    },
    f.host,
  );
  const refreshed = (
    second.resources as { configuration: { columns: Record<string, string> } }[]
  )[0].configuration;
  assert.equal(refreshed.columns.Nombre, "Manual");
  assert.equal(refreshed.columns.Clave, "");
  assert.ok(!("Borrada" in refreshed.columns));
});
for (const [name, body, expected] of [
  ["estilo plano", "{{transcripcion-texto}}", ["Hola.", "Dime."]],
  [
    "estilo con tiempos",
    "{{transcripcion-tiempos}}",
    ["[00:00] Ruben: Hola.", "[00:12] Aritz: Dime."],
  ],
  [
    "encabezados vacíos",
    "# Vacío\n{{enlace:ausente}}\n# Texto\n{{transcripcion}}",
    ["Texto", "Ruben: Hola.", "Aritz: Dime."],
  ],
  [
    "referencia ausente",
    "Ver {{enlace:ausente}}\n{{enlace:ausente}}",
    ["Ver "],
  ],
  [
    "negrita y viñeta",
    "**Hablantes:** {{hablantes}}\n- {{clave}}",
    ["Hablantes: Ruben, Aritz", "llamada"],
  ],
] as const)
  test("paridad Notion: " + name, async () => {
    const result = preview(
      await run(
        {
          operation: "preview",
          provider: "notion",
          config: { ...config, body },
          note,
        },
        folder().host,
      ),
    );
    const text = result.children.map((b) => {
      const value = b[b.type] as { rich_text: { text: { content: string } }[] };
      return value.rich_text.map((r) => r.text.content).join("");
    });
    assert.deepEqual(text, expected);
  });
test("bloques largos respetan 2000 caracteres y el prefijo no queda solo", async () => {
  const result = preview(
    await run(
      {
        operation: "preview",
        provider: "notion",
        config,
        note: {
          ...note,
          text: "x".repeat(4200),
          segments: [
            { start: 0, end: 1, speaker: "Hablante", text: "x".repeat(4200) },
          ],
        },
      },
      folder().host,
    ),
  );
  const text = result.children.map((b) =>
    (b.paragraph as { rich_text: { text: { content: string } }[] }).rich_text
      .map((r) => r.text.content)
      .join(""),
  );
  assert.equal(text.length, 3);
  assert.ok(text.every((t) => t.length <= 2000));
  assert.ok(text[0].startsWith("Hablante: x"));
});
test("sin diarización se mantienen los párrafos y no se inventan marcas", async () => {
  const result = preview(
    await run(
      {
        operation: "preview",
        provider: "notion",
        config: { ...config, body: "{{transcripcion-tiempos}}" },
        note: {
          ...note,
          segments: [
            { start: 75, end: 80, text: "Hola" },
            { start: 90, end: 99, text: "Adiós" },
          ],
          text: "Hola\nAdiós",
        },
      },
      folder().host,
    ),
  );
  assert.deepEqual(
    result.children.map((b) =>
      (b.paragraph as { rich_text: { text: { content: string } }[] }).rich_text
        .map((r) => r.text.content)
        .join(""),
    ),
    ["Hola", "Adiós"],
  );
});
test("descubrir fuentes recorre páginas y query por clave conserva una página previa", async () => {
  const f = folder();
  let page = 0;
  const calls: string[] = [];
  f.host.fetch = async (input, init) => {
    const path = String(input);
    calls.push(path);
    if (path.endsWith("/search")) {
      page++;
      return new Response(
        JSON.stringify({
          results: [
            {
              object: "data_source",
              id: "s" + page,
              title: [{ plain_text: "Notas " + page }],
              properties: { Nombre: { type: "title" } },
            },
          ],
          has_more: page === 1,
          next_cursor: page === 1 ? "next" : null,
        }),
      );
    }
    if (path.endsWith("/query"))
      return new Response(
        JSON.stringify({
          results: [
            {
              object: "page",
              id: "existing",
              url: "https://notion.so/existing",
            },
          ],
        }),
      );
    if (init?.method === "GET")
      return new Response(JSON.stringify({ results: [], has_more: false }));
    return new Response("{}");
  };
  const result = await run(
    { operation: "discover", provider: "notion" },
    f.host,
  );
  assert.equal((result.resources as unknown[]).length, 2);
  const published = await run(
    {
      operation: "publish",
      provider: "notion",
      config: {
        ...config,
        source: {
          ...config.source,
          properties: [
            ...config.source.properties,
            { name: "Clave", type: "rich_text" },
          ],
        },
        columns: { ...config.columns, Clave: "{{clave}}" },
      },
      note,
    },
    f.host,
  );
  assert.equal(published.locator, "existing");
  assert.ok(!calls.some((path) => path.endsWith("/pages")));
});
test("un 404 al actualizar crea otra página y un fallo al buscar clave nunca crea", async () => {
  const f = folder();
  let creates = 0;
  f.host.fetch = async (input) => {
    if (String(input).endsWith("/pages")) {
      creates++;
      return new Response(
        JSON.stringify({ id: "new", url: "https://notion.so/new" }),
      );
    }
    return new Response(
      JSON.stringify({
        code: "object_not_found",
        message: "borrada",
        status: 404,
      }),
      { status: 404 },
    );
  };
  const published = await run(
    {
      operation: "publish",
      provider: "notion",
      config,
      note,
      previous: { locator: "deleted" },
    },
    f.host,
  );
  assert.equal(published.locator, "new");
  assert.equal(creates, 1);
  await assert.rejects(() =>
    run(
      {
        operation: "publish",
        provider: "notion",
        config: {
          ...config,
          source: {
            ...config.source,
            properties: [
              ...config.source.properties,
              { name: "Clave", type: "rich_text" },
            ],
          },
          columns: { ...config.columns, Clave: "{{clave}}" },
        },
        note,
      },
      f.host,
    ),
  );
  assert.equal(creates, 1);
});
test("OKF regenera N documentos al cambiar título y retira el documento eliminado", async () => {
  const f = folder();
  const first = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      now,
    },
    f.host,
  );
  const changed = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note: {
        ...note,
        digest: { ...note.digest!, title: "Restore de cortes" },
      },
      previous: first.receipt,
      now,
    },
    f.host,
  );
  assert.equal(f.files[first.locator!], undefined);
  assert.equal(changed.locator, "notas/2025-09-16-restore-de-cortes.md");
  assert.match(f.files["notas/index.md"], /Restore de cortes/);
  const migrated = await run({
    operation: "migrate",
    provider: "okf",
    config: { folder: "/bundle" },
  });
  const docs = (migrated.configuration as { documents: unknown[] }).documents;
  await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle", documents: docs.slice(0, 1) },
      note: {
        ...note,
        digest: { ...note.digest!, title: "Restore de cortes" },
      },
      previous: changed.receipt,
      now,
    },
    f.host,
  );
  assert.equal(f.files["transcripciones/index.md"], undefined);
  assert.ok(
    !Object.keys(f.files).some((p) => p.startsWith("transcripciones/")),
  );
});
test("OKF evita colisiones, conserva archivos ajenos y mantiene registro manual", async () => {
  const f = folder();
  f.files["notas/2025-09-16-backups-de-cortes.md"] =
    "---\ntype: Idea\ntitle: Idea manual\n---\n";
  f.files["apuntes/mio.md"] = "Texto propio";
  f.files["log.md"] =
    "# Historial del equipo\n\nNotas libres.\n\n## 2026-01-01\n\n* Empezamos.\n";
  const first = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      now,
    },
    f.host,
  );
  assert.equal(first.locator, "notas/2025-09-16-backups-de-cortes-2.md");
  const same = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      previous: first.receipt,
      now,
    },
    f.host,
  );
  assert.equal(same.locator, first.locator);
  const log = f.files["log.md"];
  await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      previous: same.receipt,
      now,
    },
    f.host,
  );
  assert.equal(f.files["log.md"], log);
  assert.ok(log.startsWith("# Historial del equipo\n\nNotas libres."));
  assert.ok(log.endsWith("* Empezamos.\n"));
  assert.equal(f.files["apuntes/mio.md"], "Texto propio");
  assert.equal(f.files["apuntes/index.md"], undefined);
});
test("plantillas iniciales sin host conservan OKF y dejan Notion pendiente de base real", async () => {
  const okf = await run({
    operation: "template",
    provider: "okf",
    config: { folder: "/elegida" },
  });
  assert.equal((okf.configuration as { folder: string }).folder, "/elegida");
  assert.equal(
    (okf.configuration as { documents: unknown[] }).documents.length,
    2,
  );
  const notion = await run({ operation: "template", provider: "notion" });
  const validation = await run({
    operation: "validate",
    provider: "notion",
    config: notion.configuration as Record<string, unknown>,
  });
  assert.equal(validation.valid, false);
});
test("un corte de red al leer hijos se reintenta sin recrear la página", async () => {
  const f = folder();
  let reads = 0;
  let creates = 0;
  f.host.fetch = async (input, init) => {
    if (String(input).endsWith("/pages")) creates++;
    if (init?.method === "GET") {
      reads++;
      if (reads === 1) throw new TypeError("red cortada");
      return new Response(JSON.stringify({ results: [], has_more: false }));
    }
    return new Response("{}");
  };
  const result = await run(
    {
      operation: "publish",
      provider: "notion",
      config,
      note,
      previous: { locator: "existing" },
    },
    f.host,
  );
  assert.equal(result.locator, "existing");
  assert.equal(reads, 2);
  assert.equal(creates, 0);
});
test("el plan OKF exige el contenido observado antes de cada cambio", async () => {
  const f = folder();
  const apply = f.host.files.apply;
  f.host.files.apply = async (changes) => {
    for (const change of changes)
      assert.equal(change.expectedContents, f.files[change.path] ?? null);
    await apply(changes);
  };
  const first = await run(
    {
      operation: "publish",
      provider: "okf",
      config: { folder: "/bundle" },
      note,
      now,
    },
    f.host,
  );
  await run(
    {
      operation: "remove",
      provider: "okf",
      config: { folder: "/bundle" },
      previous: first.receipt,
      now,
    },
    f.host,
  );
});
test("la fecha legacy del cuerpo sigue legible y la columna usa ISO", async () => {
  const result = await run({
    operation: "migrate",
    provider: "notion",
    config: {
      source: {
        id: "s",
        title: "Notas",
        properties: [{ name: "Fecha", type: "date" }],
      },
      mapping: { byField: { date: "Fecha" } },
      template: { blocks: [{ field: { _0: "date" } }] },
    },
  });
  const configuration = result.configuration as {
    columns: Record<string, string>;
    body: string;
  };
  assert.equal(configuration.columns.Fecha, "{{fecha-iso}}");
  assert.equal(configuration.body, "**Fecha de la grabación:** {{fecha}}");
});
