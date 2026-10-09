import { LogicalPosition } from "@tauri-apps/api/dpi";
import {
  CheckMenuItem,
  Menu,
  MenuItem,
  PredefinedMenuItem,
  Submenu,
} from "@tauri-apps/api/menu";
import { ask, message, open } from "@tauri-apps/plugin-dialog";
import { desktop } from "../api";

export type MenuEntry =
  | { kind: "item"; text: string; action: () => void; enabled?: boolean; checked?: boolean }
  | { kind: "header"; text: string }
  | { kind: "separator" }
  | { kind: "submenu"; text: string; items: MenuEntry[]; enabled?: boolean };

export const item = (text: string, action: () => void, options: { enabled?: boolean; checked?: boolean } = {}): MenuEntry => ({
  kind: "item",
  text,
  action,
  ...options,
});
export const header = (text: string): MenuEntry => ({ kind: "header", text });
export const separator: MenuEntry = { kind: "separator" };
export const submenu = (text: string, items: MenuEntry[], enabled = true): MenuEntry => ({ kind: "submenu", text, items, enabled });

export function trimSeparators(entries: MenuEntry[]) {
  const kept = entries.filter((entry, index) => entry.kind !== "separator" || (index > 0 && entries[index - 1].kind !== "separator"));
  while (kept[0]?.kind === "separator") kept.shift();
  while (kept.at(-1)?.kind === "separator") kept.pop();
  return kept;
}

async function build(entry: MenuEntry): Promise<MenuItem | CheckMenuItem | Submenu | PredefinedMenuItem> {
  switch (entry.kind) {
    case "separator":
      return PredefinedMenuItem.new({ item: "Separator" });
    case "header":
      return MenuItem.new({ text: entry.text, enabled: false });
    case "submenu":
      return Submenu.new({ text: entry.text, enabled: entry.enabled ?? true, items: await Promise.all(trimSeparators(entry.items).map(build)) });
    case "item":
      return entry.checked
        ? CheckMenuItem.new({ text: entry.text, checked: true, enabled: entry.enabled ?? true, action: entry.action })
        : MenuItem.new({ text: entry.text, enabled: entry.enabled ?? true, action: entry.action });
  }
}

export async function popupMenu(entries: MenuEntry[], anchor?: Element | { x: number; y: number }) {
  const visible = trimSeparators(entries);
  if (!visible.length) return;
  if (!desktop) {
    console.info("Menú (vista de muestra):", visible.map((entry) => ("text" in entry ? entry.text : "—")).join(" | "));
    return;
  }
  const menu = await Menu.new({ items: await Promise.all(visible.map(build)) });
  if (anchor instanceof Element) {
    const box = anchor.getBoundingClientRect();
    await menu.popup(new LogicalPosition(box.left, box.bottom + 4));
  } else if (anchor) {
    await menu.popup(new LogicalPosition(anchor.x, anchor.y));
  } else {
    await menu.popup();
  }
}

export async function confirmDestructive(title: string, text: string, confirmLabel: string) {
  if (!desktop) return false;
  return ask(text, { title, kind: "warning", okLabel: confirmLabel, cancelLabel: "Cancelar" });
}

export async function alertMessage(title: string, text: string) {
  if (!desktop) {
    console.warn(`${title}: ${text}`);
    return;
  }
  await message(text, { title, kind: "warning", buttons: { ok: "Vale" } });
}

export async function chooseFiles(extensions: string[]) {
  if (!desktop) return [];
  const chosen = await open({ multiple: true, directory: false, filters: [{ name: "Audio", extensions }] });
  return Array.isArray(chosen) ? chosen : chosen ? [chosen] : [];
}

export const errorText = (failure: unknown) => (failure instanceof Error ? failure.message : String(failure));
