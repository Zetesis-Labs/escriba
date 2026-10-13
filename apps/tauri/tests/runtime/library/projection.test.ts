import { test } from "vitest";
import assert from "node:assert/strict";
import { lightPublication, lightVersion, previewVersion, PREVIEW_CHARACTERS, typedLibrary } from "../../../src/runtime/library/projection";
import { readLibraryData, readWatchedFolder, watchedFolderSchema } from "../../../src/runtime/library/model";
import { rfc3339 } from "../../../src/runtime/library/json";

const segment = (start: number, text: string) => ({ start, end: start + 2, speaker: "Ana", text, words: [{ start, end: start + 1, text }] });

test("cambiar contenido fuera del extracto invalida el detalle", () => {
  const version = { id: "v", digest: { title: "Nota", summary: "Mismo comienzo. Contenido anterior", tags: [] }, transcript: { text: "texto", segments: [] } };
  const before = lightVersion(version);
  version.digest.summary = "Mismo comienzo. Contenido renovado";
  const after = lightVersion(version);
  assert.deepEqual(before.digest, after.digest);
  assert.notEqual((before as { revision?: string }).revision, (after as { revision?: string }).revision);
});

test("la lista no carga resumen, datos ni código de publicaciones", () => {
  const version = { id: "v", digest: { title: "Título", description: "Extracto", tags: ["tema"], summary: "resumen muy largo" }, data: { large: "muchos datos" }, inputs: { source: "criterios" }, transcript: { text: "texto ".repeat(200), segments: [segment(0, "palabra")] } };
  const light = lightVersion(version) as Record<string, unknown>;
  assert.equal((light.digest as Record<string, unknown>).summary, undefined);
  assert.equal(light.data, undefined);
  assert.equal(light.inputs, undefined);
  assert.equal((light.digest as Record<string, unknown>).description, "resumen muy largo");
  assert.deepEqual((light.transcript as { segments: unknown[] }).segments, []);
  const publication = lightPublication({ destinationId: "d", provider: "notion", program: "codigo grande", configuration: { body: "plantilla" }, receipt: { url: "https://example.com/nota", state: "published", large: "respuesta completa" } });
  assert.equal(publication.program, undefined);
  assert.equal(publication.configuration, undefined);
  assert.equal((publication.receipt as Record<string, unknown>).large, undefined);
  assert.equal((publication.receipt as Record<string, unknown>).url, "https://example.com/nota");
});

test("la lista viaja sin segmentos y con un avance del texto", () => {
  const long = "palabra ".repeat(200);
  const data = readLibraryData({
    schemaVersion: 1,
    settings: { language: "es" },
    accounts: [], resolvers: [], recipes: [], destinations: [],
    recordings: [{
      id: "r", title: "nota", status: "done",
      versions: [{ id: "v", backend: "local-stt", digest: { title: "T", summary: "S", tags: [] }, transcript: { text: long, segments: [segment(0, "hola"), segment(2, "adiós")], language: "es" } }],
      publications: [{ destinationId: "d" }],
    }],
  });
  data.recordings[0]!.versions = data.recordings[0]!.versions!.map(previewVersion);
  data.recordings[0]!.publications = data.recordings[0]!.publications!.map(lightPublication);
  const light = typedLibrary(data);
  const version = (light.recordings as Record<string, unknown>[])[0]!.versions as Record<string, unknown>[];
  const transcript = version[0]!.transcript as { text: string; segments: unknown[]; duration: unknown };
  assert.deepEqual(transcript.segments, []);
  assert.equal(Array.from(transcript.text).length, PREVIEW_CHARACTERS);
  assert.equal(transcript.duration, 4);
  assert.equal((version[0]!.digest as { description: string }).description, "S");
  assert.deepEqual((light.recordings as Record<string, unknown>[])[0]!.publications, [lightPublication({ destinationId: "d" })]);
  assert.deepEqual(light.settings, data.settings);
});

test("la biblioteca visible omite lápidas sin fecha ni versiones", () => {
  const data = readLibraryData({
    schemaVersion: 1, recipes: [], destinations: [], accounts: [], resolvers: [], settings: {},
    recordings: [
      { id: "descartada", source: "/origen.m4a", sourceKey: null, legacyKey: null, status: "discarded" },
      { id: "visible", title: "Nota", createdAt: "2026-10-10T00:00:00Z", status: "pending", versions: [], publications: [] },
    ],
  });
  const light = typedLibrary(data);
  assert.equal((light.recordings as unknown[]).length, 1);
  assert.equal((light.recordings as Record<string, unknown>[])[0]!.id, "visible");
});

test("los programas compilados viajan solo con su huella", () => {
  const data = readLibraryData({
    schemaVersion: 1, accounts: [], resolvers: [], settings: {}, recordings: [],
    recipes: [{ id: "resumen", kind: "code", bundle: "var __recipe = 1;" }, { id: "default", kind: "form" }],
    destinations: [{ id: "d", program: "var __conectores = 1;" }],
  });
  const light = typedLibrary(data);
  const recipes = light.recipes as Record<string, unknown>[];
  assert.equal(recipes[0]!.bundle, undefined);
  assert.equal((recipes[0]!.bundleFingerprint as string).length, 12);
  assert.equal(recipes[1]!.bundleFingerprint, undefined);
  const destinations = light.destinations as Record<string, unknown>[];
  assert.equal(destinations[0]!.program, undefined);
  assert.equal((destinations[0]!.programFingerprint as string).length, 12);
});

test("sin texto guardado el avance sale de los segmentos", () => {
  const version = lightVersion({ id: "v", transcript: { text: "", segments: [segment(0, "hola"), segment(2, "adiós")], duration: 9.5 } });
  assert.equal(version.transcript!.text, "hola\nadiós");
  assert.equal(version.transcript!.duration, 9.5);
});

test("carpeta guardada conserva nulos, ausentes y extensiones", () => {
  const original = { id: "folder-1", path: "/tmp/synthetic", name: "Sintética", style: null, accessBookmark: null, futureSetting: { enabled: true } };
  assert.deepEqual(readWatchedFolder(original), original);
  const withoutOptionals = { id: "folder-2", path: "/tmp/other", name: "Otra" };
  assert.deepEqual(readWatchedFolder(withoutOptionals), withoutOptionals);
  const damaged = { id: "folder-3", path: "/tmp/old", name: "Antigua", accessBookmark: "damaged" };
  assert.deepEqual(readWatchedFolder(damaged), damaged);
  for (const invalid of [{ id: 7, path: "/tmp/synthetic", name: "Sintética" }, { id: "folder-1", path: false, name: "Sintética" }])
    assert.ok(!watchedFolderSchema.safeParse(invalid).success);
});

test("las fechas se escriben como en Rust, con milisegundos solo si los hay", () => {
  assert.equal(rfc3339(new Date(1_700_000_000_000)), "2023-11-14T22:13:20+00:00");
  assert.equal(rfc3339(new Date(1_700_000_000_123)), "2023-11-14T22:13:20.123+00:00");
});
