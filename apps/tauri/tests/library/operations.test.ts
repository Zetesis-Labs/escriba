import { expect, test, vi } from "vitest";
import type { Recording } from "../../src/types";

const processRecording = vi.fn(async () => null);
const call = vi.fn(async (_method: string, _params?: unknown) => ({ id: "v3" }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ save: vi.fn() }));
vi.mock("../../src/api", () => ({ call }));
vi.mock("../../src/runtime", () => ({ processRecording, cancelProcessing: vi.fn(), publishRecording: vi.fn(), unpublishRecording: vi.fn() }));

const recording: Recording = {
  id: "r",
  title: "Nota",
  createdAt: "2026-10-16T10:00:00Z",
  source: "voice",
  audioPath: null,
  duration: 0,
  status: "done",
  currentVersionId: "v1",
  versions: [
    { id: "v1", createdAt: "2026-10-16T10:00:00Z", backend: "local-stt", transcript: { text: "uno", segments: [] } },
    { id: "v2", createdAt: "2026-10-16T11:00:00Z", backend: "local-stt", transcript: { text: "dos", segments: [] } },
  ],
  publications: [],
};

test("Resumir y Reprocesar desde la nota parten de la versión abierta", async () => {
  const operations = await import("../../src/library/operations");
  await operations.summarize(recording);
  await operations.reprocess(recording, "serie:transcribir", { idioma: "es" });
  expect(processRecording.mock.calls).toEqual([
    ["r", { recipeId: "serie:resumir", force: true, baseVersionId: "v1" }],
    ["r", { recipeId: "serie:transcribir", force: true, values: { idioma: "es" }, baseVersionId: "v1" }],
  ]);
});

test("renombrar un hablante guarda una corrección con los criterios, el resumen y los datos de la versión abierta", async () => {
  const operations = await import("../../src/library/operations");
  const inputs = { backend: "local-stt", diarize: true };
  const open = {
    id: "v1",
    createdAt: "2026-10-16T10:00:00Z",
    backend: "local-stt",
    inputs,
    digest: { title: "T", summary: "S", tags: [] },
    data: { tema: "a" },
    transcript: { text: "hola", segments: [{ start: 0, end: 1, text: "hola", speaker: "Speaker 1" }] },
  };
  await operations.renameSpeaker({ ...recording, versions: [open], currentVersionId: "v1" }, "Speaker 1", "Ana");
  const saved = call.mock.calls.find(([method]) => method === "version_save")?.[1] as Record<string, unknown>;
  expect([saved.sourceVersionId, saved.inputs, saved.digest, saved.data, saved.backend]).toEqual(["v1", inputs, open.digest, open.data, "correccion"]);
});
