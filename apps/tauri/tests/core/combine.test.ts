import { expect, test } from "vitest";
import { combinedRecord, combineBlocker, initialOrder, moveWithin, piecesLabel } from "../../src/core/combine";
import type { Recording } from "../../src/types";

const recording = (id: string, createdAt: string, extra: Partial<Recording> = {}): Recording => ({
  id,
  title: `Nota ${id}`,
  createdAt,
  source: "voice",
  audioPath: `/audio/${id}.m4a`,
  duration: 0,
  status: "done",
  versions: [],
  publications: [],
  ...extra,
});

const a = recording("a", "2026-10-16T10:00:00Z");
const b = recording("b", "2026-10-16T09:00:00Z");
const c = recording("c", "2026-10-16T11:00:00Z");

test("el orden inicial va de la más antigua a la más reciente", () => {
  expect(initialOrder([a, b, c]).map((item) => item.id)).toEqual(["b", "a", "c"]);
});

test("subir y bajar una pieza devuelve otro orden y no se sale de los extremos", () => {
  const order = [b, a, c];
  expect(moveWithin(order, 2, -1).map((item) => item.id)).toEqual(["b", "c", "a"]);
  expect(moveWithin(order, 0, -1)).toBe(order);
  expect(moveWithin(order, 2, 1)).toBe(order);
});

test("combinar exige dos o más, todas con copia de audio, ninguna descartada ni con trabajo en marcha", () => {
  const busy = (id: string) => id === "c";
  expect(combineBlocker([a], () => false)).toBe("Elige al menos dos grabaciones");
  expect(combineBlocker([a, recording("x", "2026-10-16T12:00:00Z", { audioPath: null })], () => false)).toBe("«Nota x» no tiene copia de audio");
  expect(combineBlocker([a, recording("y", "2026-10-16T12:00:00Z", { status: "discarded" })], () => false)).toBe("«Nota y» está borrada de la biblioteca");
  expect(combineBlocker([a, c], busy)).toBe("«Nota c» tiene un trabajo en marcha");
  expect(combineBlocker([a, b], () => false)).toBeNull();
});

test("el registro combinado toma la fecha de la primera pieza y los segundos que midió el host", () => {
  const record = combinedRecord([a, b], { duration: 125.5, parts: [{ start: 0, end: 60 }, { start: 61, end: 125.5 }] });
  expect(record).toEqual({
    title: "Grabación combinada",
    createdAt: "2026-10-16T10:00:00Z",
    source: "Combinación",
    duration: 125.5,
    parts: [
      { recordingId: "a", title: "Nota a", start: 0, end: 60 },
      { recordingId: "b", title: "Nota b", start: 61, end: 125.5 },
    ],
  });
});

test("el registro combinado rechaza medidas que no casan con las piezas", () => {
  expect(() => combinedRecord([a, b], { duration: 10, parts: [{ start: 0, end: 10 }] })).toThrow(/piezas/);
  expect(() => combinedRecord([a, b], { duration: 10, parts: [{ start: 0, end: 6 }, { start: 5, end: 10 }] })).toThrow(/orden/);
});

test("las piezas se presentan con su título y su minuto de inicio y fin", () => {
  expect(piecesLabel([{ recordingId: "a", title: "Reunión", start: 0, end: 61 }, { recordingId: "b", title: "Sigue", start: 62, end: 3725 }])).toEqual([
    "Reunión · 00:00 – 01:01",
    "Sigue · 01:02 – 1:02:05",
  ]);
});
