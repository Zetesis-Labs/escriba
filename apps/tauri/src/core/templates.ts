export interface TemplateToken {
  marker: string;
}

export type TemplatePiece = { kind: "text"; text: string } | { kind: "token"; token: TemplateToken };

export type TemplateContext = "body" | "property" | "path";
export interface LinkTarget { id: string; name: string }
export interface TokenSuggestion { token: TemplateToken; label: string; help: string }

const catalog: readonly [string, string, string][] = [
  ["titulo", "Título", "El título del resumen, o el principio del texto"],
  ["descripcion", "Descripción", "La primera frase del resumen"],
  ["resumen", "Resumen", "El resumen completo"],
  ["etiquetas", "Etiquetas", "Las etiquetas del resumen"],
  ["fecha", "Fecha", "Fecha y hora, para leer"],
  ["fecha-iso", "Fecha ISO", "Fecha y hora en ISO 8601"],
  ["dia", "Día", "AAAA-MM-DD, para nombres de fichero"],
  ["hablantes", "Hablantes", "Quién habla"],
  ["duracion", "Duración", "mm:ss"],
  ["segundos", "Segundos", "La duración en segundos"],
  ["clave", "Clave", "El identificador de la grabación"],
  ["origen", "Fichero de origen", "La ruta del fichero de audio"],
  ["audio", "Audio", "Enlace al fichero de audio"],
  ["transcripcion", "Transcripción", "Un párrafo por hablante"],
  ["transcripcion-tiempos", "Transcripción con tiempos", "Cada párrafo con su minuto"],
  ["transcripcion-texto", "Transcripción (solo texto)", "Sin hablantes ni tiempos"],
];
export const templateCatalog: TemplateToken[] = catalog.map(([marker]) => ({ marker }));
export const templatePathCatalog: TemplateToken[] = ["dia", "titulo", "clave"].map((marker) => ({ marker }));

const knownMarkers = new Set(catalog.map(([marker]) => marker));

export function templateToken(marker: string): TemplateToken | null {
  return knownMarkers.has(marker) || (marker.startsWith("enlace:") && marker.length > "enlace:".length) ? { marker } : null;
}

export function templatePieces(source: string): TemplatePiece[] {
  const pieces: TemplatePiece[] = [];
  let literal = "";
  let rest = source;
  while (true) {
    const open = rest.indexOf("{{");
    if (open < 0) break;
    literal += rest.slice(0, open);
    const afterOpen = rest.slice(open + 2);
    const close = afterOpen.indexOf("}}");
    const token = close < 0 ? null : templateToken(afterOpen.slice(0, close));
    if (!token) {
      literal += "{{";
      rest = afterOpen;
      continue;
    }
    if (literal) pieces.push({ kind: "text", text: literal });
    literal = "";
    pieces.push({ kind: "token", token });
    rest = afterOpen.slice(close + 2);
  }
  literal += rest;
  if (literal) pieces.push({ kind: "text", text: literal });
  return pieces;
}

export function templateSource(pieces: TemplatePiece[]): string {
  return pieces.map((piece) => piece.kind === "text" ? piece.text : `{{${piece.token.marker}}}`).join("");
}

export function templateNormalizeSource(source: string, multiline: boolean): string {
  const lines = source.replace(/\r\n?|\n/g, "\n");
  return multiline ? lines : lines.replace(/\n/g, " ");
}

function visualUnits(source: string): string[] {
  return templatePieces(source).flatMap((piece) => piece.kind === "token"
    ? [`{{${piece.token.marker}}}`]
    : piece.text.split(""));
}

export function templateSelectedSource(source: string, start: number, end: number): string {
  return visualUnits(source).slice(start, end).join("");
}

export function templateReplaceSelection(source: string, start: number, end: number, replacement: string, multiline: boolean): { source: string; caret: number } {
  const original = visualUnits(source);
  const inserted = visualUnits(templateNormalizeSource(replacement, multiline));
  const from = Math.max(0, Math.min(start, original.length));
  const to = Math.max(from, Math.min(end, original.length));
  return {
    source: [...original.slice(0, from), ...inserted, ...original.slice(to)].join(""),
    caret: from + inserted.length,
  };
}

export function templateSlashQuery(prefix: string, context: TemplateContext): { start: number; query: string } | null {
  let query = "";
  for (let index = prefix.length - 1; index >= 0 && prefix.length - index <= 32; index--) {
    const character = prefix[index];
    if (character === "/") {
      const previous = index > 0 ? prefix[index - 1] : null;
      const trigger = previous === null || /\s|\uFFFC/u.test(previous)
        || (context === "path" ? "/-_".includes(previous) : "([".includes(previous));
      return trigger ? { start: index, query } : null;
    }
    if (/\s|\uFFFC/u.test(character)) return null;
    query = character + query;
  }
  return null;
}

export function templateTokenLabel(token: TemplateToken, names: Record<string, string> = {}): string {
  if (token.marker.startsWith("enlace:")) {
    const name = names[token.marker.slice("enlace:".length)];
    return name !== undefined ? `Enlace a «${name}»` : "Enlace a un documento que ya no existe";
  }
  return catalog.find(([marker]) => marker === token.marker)?.[1] ?? "";
}

export function templateTokenHelp(token: TemplateToken): string {
  if (token.marker.startsWith("enlace:")) return "Enlace a ese documento de la misma grabación";
  return catalog.find(([marker]) => marker === token.marker)?.[2] ?? "";
}

const folded = (text: string) => text.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase("es").trim();

export function tokenSuggestions(query: string, context: TemplateContext, links: LinkTarget[] = [], current?: string): TokenSuggestion[] {
  const names: Record<string, string> = {};
  for (const { id, name } of links) if (!(id in names)) names[id] = name;
  const candidates = context === "path"
    ? templatePathCatalog
    : [...templateCatalog, ...links.filter(({ id }) => id !== current).map(({ id }) => ({ marker: `enlace:${id}` }))];
  const needle = folded(query);
  return candidates
    .map((token) => ({ token, label: templateTokenLabel(token, names), help: templateTokenHelp(token) }))
    .filter(({ token, label }) => !needle
      || folded(token.marker).startsWith(needle)
      || folded(label).split(/[^\p{L}\p{N}]+/u).some((word) => word.startsWith(needle)));
}
