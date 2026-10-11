import { expect, test } from "vitest";
import { recordingRevision } from "../../src/core/recordingDetail";
import type { Recording } from "../../src/types";

const recording: Recording = {
  id: "nota-1",
  title: "Nota",
  createdAt: "2026-10-11T00:00:00Z",
  source: "/source/nota-1.m4a",
  status: "done",
  audioPath: "/audio/nota-1.m4a",
  duration: 30,
  versions: [{ id: "v1", revision: "0000000000000001", createdAt: "2026-10-11T00:00:00Z", backend: "local", transcript: { text: "abc", segments: [] }, digest: { title: "Nota", summary: "abc", tags: [] } }],
  publications: [],
};

test("una revisión nueva invalida el detalle aunque el resumen conserve la longitud", () => {
  const revised = {
    ...recording,
    versions: [{ ...recording.versions[0], revision: "0000000000000002", digest: { title: "Nota", summary: "xyz", tags: [] } }],
  };

  expect(recordingRevision(revised)).not.toBe(recordingRevision(recording));
});

test("remapear la receta invalida el detalle aunque el hash de la versión sea igual", () => {
  const remapped = {
    ...recording,
    versions: [{ ...recording.versions[0], recipeId: "receta-nueva" }],
  };

  expect(recordingRevision(remapped)).not.toBe(recordingRevision(recording));
});
