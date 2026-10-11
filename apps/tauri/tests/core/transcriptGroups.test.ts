import { expect, test } from "vitest";
import { groupSelectionRanges, transcriptGroups } from "../../src/core/transcriptGroups";
import type { Segment } from "../../src/types";

test("agrupa solo intervenciones contiguas del mismo hablante y conserva índices", () => {
  const segments: Segment[] = [
    { start: 0, end: 1, text: "Uno.", speaker: "Ana" },
    { start: 1, end: 2, text: "Dos.", speaker: "Ana" },
    { start: 2, end: 3, text: "Tres.", speaker: "Luis" },
    { start: 3, end: 4, text: "Cuatro.", speaker: "Ana" },
    { start: 4, end: 5, text: "Cinco." },
    { start: 5, end: 6, text: "Seis.", speaker: "" },
  ];
  expect(transcriptGroups(segments)).toEqual([
    { speaker: "Ana", indices: [0, 1] },
    { speaker: "Luis", indices: [2] },
    { speaker: "Ana", indices: [3] },
    { speaker: null, indices: [4, 5] },
  ]);
  expect(segments).toHaveLength(6);
  expect(transcriptGroups([])).toEqual([]);
  expect(groupSelectionRanges(transcriptGroups(segments)[0], segments)).toEqual([
    { segment: 0, start: 0, end: 4 },
    { segment: 1, start: 0, end: 4 },
  ]);
});
