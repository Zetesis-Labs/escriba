export interface Selection {
  readonly ids: readonly string[];
  readonly last: string | null;
}

export const emptySelection: Selection = { ids: [], last: null };

const inListOrder = (ids: Iterable<string>, order: readonly string[]) => {
  const chosen = new Set(ids);
  return order.filter((id) => chosen.has(id));
};

export function pick(selection: Selection, order: readonly string[], id: string, modifiers: { toggle?: boolean; range?: boolean }): Selection {
  if (modifiers.toggle) {
    const chosen = new Set(selection.ids);
    if (chosen.has(id)) chosen.delete(id);
    else chosen.add(id);
    const ids = inListOrder(chosen, order);
    return ids.length ? { ids, last: chosen.has(id) ? id : (ids.at(-1) ?? null) } : emptySelection;
  }
  if (modifiers.range && selection.last !== null) {
    const from = order.indexOf(selection.last);
    const to = order.indexOf(id);
    if (from >= 0 && to >= 0) return { ids: order.slice(Math.min(from, to), Math.max(from, to) + 1), last: id };
  }
  return { ids: [id], last: id };
}

export function moveSelection(selection: Selection, order: readonly string[], delta: 1 | -1): Selection {
  if (selection.last === null) return selection;
  const index = order.indexOf(selection.last);
  const next = order[Math.min(Math.max(index + delta, 0), order.length - 1)];
  return next === undefined ? selection : { ids: [next], last: next };
}

export function pruneSelection(selection: Selection, order: readonly string[]): Selection {
  const ids = inListOrder(selection.ids, order);
  if (ids.length === selection.ids.length && (selection.last === null || ids.includes(selection.last))) return selection;
  if (!ids.length) return emptySelection;
  return { ids, last: selection.last !== null && ids.includes(selection.last) ? selection.last : (ids.at(-1) ?? null) };
}
