import { expect, test } from "vitest";
import { emptySelection, moveSelection, pick, pruneSelection, type Selection } from "../../src/core/selection";

const order = ["a", "b", "c", "d", "e"];

test("un clic marca solo esa fila y la deja como última marcada", () => {
  const selection = pick(emptySelection, order, "c", {});
  expect(selection).toEqual({ ids: ["c"], last: "c" });
  expect(pick(selection, order, "a", {})).toEqual({ ids: ["a"], last: "a" });
});

test("⌘-clic añade o quita una fila y la última marcada es la tocada", () => {
  const added = pick(pick(emptySelection, order, "b", {}), order, "d", { toggle: true });
  expect(added).toEqual({ ids: ["b", "d"], last: "d" });
  const removed = pick(added, order, "b", { toggle: true });
  expect(removed).toEqual({ ids: ["d"], last: "d" });
});

test("quitar con ⌘-clic la única marcada deja la selección vacía", () => {
  expect(pick(pick(emptySelection, order, "b", {}), order, "b", { toggle: true })).toEqual(emptySelection);
});

test("⇧-clic marca el tramo desde la última marcada en el orden de la lista, en ambos sentidos", () => {
  const from = pick(emptySelection, order, "d", {});
  expect(pick(from, order, "b", { range: true })).toEqual({ ids: ["b", "c", "d"], last: "b" });
  expect(pick(from, order, "e", { range: true })).toEqual({ ids: ["d", "e"], last: "e" });
});

test("⇧-clic sin nada marcado es un clic", () => {
  expect(pick(emptySelection, order, "c", { range: true })).toEqual({ ids: ["c"], last: "c" });
});

test("las flechas mueven una marca única desde la última marcada y se paran en los extremos", () => {
  const several: Selection = { ids: ["b", "d"], last: "d" };
  expect(moveSelection(several, order, 1)).toEqual({ ids: ["e"], last: "e" });
  expect(moveSelection({ ids: ["e"], last: "e" }, order, 1)).toEqual({ ids: ["e"], last: "e" });
  expect(moveSelection(emptySelection, order, -1)).toEqual(emptySelection);
});

test("al desaparecer filas, la selección se queda con las que siguen y la última marcada con una de ellas", () => {
  const selection: Selection = { ids: ["a", "c", "e"], last: "c" };
  expect(pruneSelection(selection, ["a", "e"])).toEqual({ ids: ["a", "e"], last: "e" });
  expect(pruneSelection(selection, ["a", "c", "e"])).toBe(selection);
  expect(pruneSelection(selection, [])).toEqual(emptySelection);
});
