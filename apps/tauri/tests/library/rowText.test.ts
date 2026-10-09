import { describe, expect, test } from "vitest";
import { recordingSubline } from "../../src/library/rowText";
import type { Recording, Version } from "../../src/types";

const recording = (overrides: Partial<Recording> = {}): Recording => ({
  id: "r1",
  title: "Nota",
  createdAt: "2026-10-09T10:00:00Z",
  source: "voiceMemos",
  audioPath: "/audio/r1.m4a",
  duration: 60,
  status: "pending",
  versions: [],
  publications: [],
  ...overrides,
});
const version = (text: string, summary?: string): Version => ({
  id: "v1",
  createdAt: "2026-10-09T10:01:00Z",
  backend: "local-stt",
  transcript: { text, segments: [] },
  digest: summary ? { title: "", summary, tags: [] } : null,
});

describe("la fila de una grabación dice lo que está pasando", () => {
  test("con un trabajo en curso muestra su etapa aunque haya una versión anterior", () => {
    const job = { recordingId: "r1", stage: "Resumiendo", startedAt: 0 };
    expect(
      recordingSubline(recording({ versions: [version("texto", "resumen")] }), job),
    ).toBe("Resumiendo");
  });
  test("sin trabajo, una nota pendiente está en cola como en la app Swift", () => {
    expect(recordingSubline(recording())).toBe("En cola");
  });
  test("sin trabajo, una nota en proceso dice que se está transcribiendo", () => {
    expect(recordingSubline(recording({ status: "processing" }))).toBe("Transcribiendo");
  });
  test("una nota terminada enseña su resumen, y sin resumen su texto", () => {
    expect(recordingSubline(recording({ status: "done", versions: [version("texto", "resumen")] }))).toBe("resumen");
    expect(recordingSubline(recording({ status: "done", versions: [version("texto")] }))).toBe("texto");
  });
  test("una nota fallida enseña su error", () => {
    expect(recordingSubline(recording({ status: "failed", error: "sin audio" }))).toBe("sin audio");
  });
});
