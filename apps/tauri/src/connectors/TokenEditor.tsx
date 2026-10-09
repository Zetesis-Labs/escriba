import { PlusCircle } from "lucide-react";
import { useLayoutEffect, useRef, useState } from "react";
import {
  templateNormalizeSource, templatePieces, templateReplaceSelection, templateSelectedSource,
  templateSlashQuery, templateTokenLabel, tokenSuggestions,
  type LinkTarget, type TemplateContext, type TemplateToken, type TokenSuggestion,
} from "../core/templates";
import { item, popupMenu } from "../mac/native";
import "./token-editor.css";

interface TokenEditorProps {
  value: string;
  onChange: (value: string) => void;
  context: TemplateContext;
  links?: LinkTarget[];
  current?: string;
  placeholder?: string;
  multiline?: boolean;
}

type SlashMenu = { start: number; items: TokenSuggestion[]; selected: number; x: number; y: number; query: string };

function isToken(node: Node): node is HTMLElement {
  return node instanceof HTMLElement && node.dataset.token !== undefined;
}

function inlineText(node: Node, markers: boolean): string {
  if (isToken(node)) return markers ? `{{${node.dataset.token}}}` : "\uFFFC";
  if (node.nodeType === Node.TEXT_NODE) return node.textContent ?? "";
  if (node instanceof HTMLBRElement) return "\n";
  const children = Array.from(node.childNodes);
  if (children.length === 1 && children[0] instanceof HTMLBRElement) return "";
  return children.map((child, index) => child instanceof HTMLBRElement && index === children.length - 1 && children[index - 1] instanceof HTMLBRElement
    ? "" : inlineText(child, markers)).join("");
}

function editorText(node: Node, markers: boolean): string {
  const children = Array.from(node.childNodes);
  const blocks = children.some((child) => child instanceof HTMLElement && child.matches("div, p"));
  if (!blocks) return children.map((child) => inlineText(child, markers)).join("");
  return children.map((child) => inlineText(child, markers)).join("\n");
}

function selectionOffset(editor: HTMLElement): number | null {
  const selection = window.getSelection();
  if (!selection?.rangeCount || !editor.contains(selection.anchorNode)) return null;
  return offsetAt(editor, selection.anchorNode!, selection.anchorOffset);
}

function offsetAt(editor: HTMLElement, node: Node, offset: number): number {
  const lines = Array.from(editor.children);
  const line = node === editor ? null : (node instanceof Element ? node : node.parentElement)?.closest(".token-editor-line");
  if (!line) {
    const before = lines.slice(0, offset);
    return before.reduce((total, child) => total + inlineText(child, false).length, 0) + Math.min(before.length, lines.length - 1);
  }
  const index = lines.indexOf(line);
  const before = lines.slice(0, index);
  const prefix = document.createRange();
  prefix.selectNodeContents(line);
  prefix.setEnd(node, offset);
  const within = Math.min(inlineText(prefix.cloneContents(), false).length, inlineText(line, false).length);
  return before.reduce((total, child) => total + inlineText(child, false).length + 1, 0) + within;
}

function selectionBounds(editor: HTMLElement): { start: number; end: number } | null {
  const selection = window.getSelection();
  if (!selection?.rangeCount || !editor.contains(selection.anchorNode) || !editor.contains(selection.focusNode)) return null;
  const range = selection.getRangeAt(0);
  return { start: offsetAt(editor, range.startContainer, range.startOffset), end: offsetAt(editor, range.endContainer, range.endOffset) };
}

function pointAt(editor: HTMLElement, offset: number): { node: Node; offset: number } {
  let remaining = offset;
  const lines = Array.from(editor.children);
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex];
    for (const node of Array.from(line.childNodes)) {
      const length = isToken(node) ? 1 : node.nodeType === Node.TEXT_NODE ? (node.textContent ?? "").length : 0;
      if (remaining <= length && node.nodeType === Node.TEXT_NODE) return { node, offset: remaining };
      if (remaining <= length && isToken(node)) return { node: line, offset: Array.from(line.childNodes).indexOf(node) + remaining };
      remaining -= length;
    }
    if (remaining === 0 || lineIndex === lines.length - 1) return { node: line, offset: line.childNodes.length };
    remaining -= 1;
  }
  return { node: editor, offset: 0 };
}

function setSelection(editor: HTMLElement, from: number, to = from) {
  const start = pointAt(editor, Math.max(0, from));
  const end = pointAt(editor, Math.max(0, to));
  const range = document.createRange();
  range.setStart(start.node, start.offset);
  range.setEnd(end.node, end.offset);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
}

function render(editor: HTMLElement, source: string, names: Record<string, string>, multiline: boolean) {
  editor.replaceChildren();
  const lines = templateNormalizeSource(source, multiline).split("\n");
  for (const lineSource of lines) {
    const line = document.createElement("div");
    line.className = "token-editor-line";
    if (multiline) {
      const heading = lineSource.match(/^(#{1,6})\s/);
      if (heading) line.dataset.heading = String(Math.min(heading[1].length, 3));
    }
    for (const piece of templatePieces(lineSource)) {
      if (piece.kind === "text") line.append(document.createTextNode(piece.text));
      else {
        const pill = document.createElement("span");
        pill.className = "token-editor-pill";
        pill.contentEditable = "false";
        pill.dataset.token = piece.token.marker;
        pill.textContent = templateTokenLabel(piece.token, names);
        line.append(pill);
      }
    }
    if (!line.childNodes.length) line.append(document.createElement("br"));
    editor.append(line);
  }
}

function slashQuery(editor: HTMLElement, context: TemplateContext): { start: number; query: string } | null {
  const selection = window.getSelection();
  if (!selection?.rangeCount || !selection.isCollapsed) return null;
  const caret = selectionOffset(editor);
  return caret === null ? null : templateSlashQuery(editorText(editor, false).slice(0, caret), context);
}

export function TokenEditor({ value, onChange, context, links = [], current, placeholder = "", multiline = false }: TokenEditorProps) {
  const editor = useRef<HTMLDivElement>(null);
  const plus = useRef<HTMLButtonElement>(null);
  const savedRange = useRef<{ start: number; end: number } | null>(null);
  const dismissedSlash = useRef<{ start: number; query: string } | null>(null);
  const composing = useRef(false);
  const [slashMenu, setSlashMenu] = useState<SlashMenu | null>(null);
  const names: Record<string, string> = {};
  for (const { id, name } of links) if (!(id in names)) names[id] = name;
  const namesKey = JSON.stringify(links);

  useLayoutEffect(() => {
    const element = editor.current;
    if (!element) return;
    if (editorText(element, true) === templateNormalizeSource(value, multiline) && element.dataset.names === namesKey) return;
    const caret = selectionOffset(element);
    render(element, value, names, multiline);
    element.dataset.names = namesKey;
    if (caret !== null) setSelection(element, caret);
  }, [value, namesKey, multiline]);

  function rememberRange() {
    if (!editor.current) return;
    savedRange.current = selectionBounds(editor.current) ?? savedRange.current;
  }

  function refreshSuggestions() {
    const element = editor.current;
    if (!element) return;
    const query = slashQuery(element, context);
    if (!query) dismissedSlash.current = null;
    if (query && dismissedSlash.current?.start === query.start && dismissedSlash.current.query === query.query) return;
    dismissedSlash.current = null;
    const items = query ? tokenSuggestions(query.query, context, links, current) : [];
    if (!query || !items.length) { setSlashMenu(null); return; }
    const range = window.getSelection()?.getRangeAt(0);
    const rect = range?.getBoundingClientRect() ?? element.getBoundingClientRect();
    setSlashMenu((previous) => ({
      start: query.start, query: query.query, items,
      selected: previous?.query === query.query ? Math.min(previous.selected, items.length - 1) : 0,
      x: rect.left, y: rect.bottom + 4,
    }));
  }

  function sync() {
    const element = editor.current;
    if (!element || composing.current) return;
    const caret = selectionOffset(element);
    const source = templateNormalizeSource(editorText(element, true), multiline);
    render(element, source, names, multiline);
    element.dataset.names = namesKey;
    if (caret !== null) setSelection(element, caret);
    onChange(source);
    rememberRange();
    refreshSuggestions();
  }

  function insertToken(token: TemplateToken, start?: number) {
    const element = editor.current;
    if (!element) return;
    const bounds = selectionBounds(element) ?? savedRange.current ?? { start: 0, end: 0 };
    const from = start ?? savedRange.current?.start ?? bounds.start;
    const to = start === undefined ? savedRange.current?.end ?? bounds.end : bounds.end;
    applyReplacement(`{{${token.marker}}}`, from, to);
    setSlashMenu(null);
    element.focus();
  }

  function applyReplacement(replacement: string, start: number, end: number) {
    const element = editor.current;
    if (!element) return;
    const result = templateReplaceSelection(editorText(element, true), start, end, replacement, multiline);
    render(element, result.source, names, multiline);
    element.dataset.names = namesKey;
    setSelection(element, result.caret);
    savedRange.current = { start: result.caret, end: result.caret };
    onChange(result.source);
    refreshSuggestions();
  }

  function onCopy(event: React.ClipboardEvent<HTMLDivElement>, cut: boolean) {
    const element = editor.current;
    const bounds = element ? selectionBounds(element) : null;
    if (!element || !bounds || bounds.start === bounds.end) return;
    event.preventDefault();
    event.clipboardData.setData("text/plain", templateSelectedSource(editorText(element, true), bounds.start, bounds.end));
    if (cut) applyReplacement("", bounds.start, bounds.end);
  }

  function onPaste(event: React.ClipboardEvent<HTMLDivElement>) {
    event.preventDefault();
    const bounds = editor.current ? selectionBounds(editor.current) : null;
    if (!bounds) return;
    applyReplacement(event.clipboardData.getData("text/plain"), bounds.start, bounds.end);
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    if (slashMenu) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        setSlashMenu({ ...slashMenu, selected: Math.max(0, Math.min(slashMenu.items.length - 1, slashMenu.selected + (event.key === "ArrowDown" ? 1 : -1))) });
        return;
      }
      if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault();
        insertToken(slashMenu.items[slashMenu.selected].token, slashMenu.start);
        return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        dismissedSlash.current = { start: slashMenu.start, query: slashMenu.query };
        setSlashMenu(null);
        return;
      }
    }
    if (!multiline && event.key === "Enter") event.preventDefault();
  }

  const all = tokenSuggestions("", context, links, current);
  return <div className={`token-editor ${multiline ? "multiline" : "single"}`}>
    <div
      ref={editor}
      className="token-editor-field"
      contentEditable
      role="textbox"
      aria-multiline={multiline}
      aria-label={placeholder || "Plantilla"}
      data-placeholder={placeholder}
      suppressContentEditableWarning
      onInput={sync}
      onKeyDown={onKeyDown}
      onKeyUp={(event) => { rememberRange(); if (event.key !== "Escape") refreshSuggestions(); }}
      onMouseUp={() => { rememberRange(); refreshSuggestions(); }}
      onFocus={rememberRange}
      onBlur={() => setSlashMenu(null)}
      onCompositionStart={() => { composing.current = true; }}
      onCompositionEnd={() => { composing.current = false; sync(); }}
      onCopy={(event) => onCopy(event, false)}
      onCut={(event) => onCopy(event, true)}
      onPaste={onPaste}
    />
    <button
      ref={plus}
      type="button"
      className="token-editor-add"
      aria-label="Insertar un dato"
      title="Insertar un dato aquí (o escribe / en el texto)"
      onMouseDown={rememberRange}
      onClick={() => void popupMenu(all.map(({ label, token }) => item(label, () => insertToken(token))), plus.current ?? undefined)}
    ><PlusCircle size={15} /></button>
    {slashMenu && <div className="token-editor-suggestions" style={{ left: slashMenu.x, top: slashMenu.y }} role="listbox">
      {slashMenu.items.map((suggestion, index) => <button
        key={suggestion.token.marker}
        type="button"
        className={index === slashMenu.selected ? "selected" : ""}
        role="option"
        aria-selected={index === slashMenu.selected}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => insertToken(suggestion.token, slashMenu.start)}
      ><span>{suggestion.label}</span><small>{suggestion.help}</small></button>)}
    </div>}
  </div>;
}
