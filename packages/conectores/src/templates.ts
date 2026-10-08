import type { Note } from "./types.js";
const months = [
  "enero",
  "febrero",
  "marzo",
  "abril",
  "mayo",
  "junio",
  "julio",
  "agosto",
  "septiembre",
  "octubre",
  "noviembre",
  "diciembre",
];
const tokens = new Set([
  "titulo",
  "descripcion",
  "resumen",
  "etiquetas",
  "fecha",
  "fecha-iso",
  "dia",
  "hablantes",
  "duracion",
  "segundos",
  "clave",
  "origen",
  "audio",
  "transcripcion",
  "transcripcion-tiempos",
  "transcripcion-texto",
]);
export const marker = /\{\{([^{}]+)\}\}/g;
export function render(text: string, value: (token: string) => string): string {
  return text.replace(marker, (raw, token: string) =>
    tokens.has(token) || (token.startsWith("enlace:") && token.length > 7)
      ? value(token)
      : raw,
  );
}
export function sole(text: string): string | undefined {
  const m = text.trim().match(/^\{\{([^{}]+)\}\}$/);
  return m && (tokens.has(m[1]) || m[1].startsWith("enlace:"))
    ? m[1]
    : undefined;
}
export function clock(seconds: number): string {
  const n = Math.max(0, Math.floor(seconds));
  return `${(n >= 3600 ? Math.floor(n / 3600) + ":" : "") + String(Math.floor((n % 3600) / 60)).padStart(2, "0")}:${String(n % 60).padStart(2, "0")}`;
}
export function dateValues(iso: string, timeZone: string) {
  const date = new Date(iso);
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(date)
      .map((p) => [p.type, p.value]),
  );
  const { year, month, day, hour, minute, second } = parts;
  const offset =
    (Date.UTC(+year, +month - 1, +day, +hour, +minute, +second) -
      Math.floor(date.getTime() / 1000) * 1000) /
    60000;
  const suffix =
    offset === 0
      ? "Z"
      : `${offset < 0 ? "-" : "+"}${String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0")}:${String(Math.abs(offset) % 60).padStart(2, "0")}`;
  return {
    day: `${year}-${month}-${day}`,
    iso: `${year}-${month}-${day}T${hour}:${minute}:${second}${suffix}`,
    long: `${+day} de ${months[+month - 1]} de ${year}, ${hour}:${minute}`,
  };
}
export function monthHeading(key: string) {
  const [year, month] = key.split("-");
  const name = months[+month - 1];
  return name ? `${name[0].toUpperCase()}${name.slice(1)} de ${year}` : "Otras";
}
export function turns(note: Note) {
  if (!note.segments.some((s) => s.speaker))
    return [{ text: note.text, speaker: undefined, start: undefined }];
  const result: { text: string; speaker?: string | null; start?: number }[] =
    [];
  for (const s of note.segments) {
    const last = result[result.length - 1];
    if (last && last.speaker === s.speaker) last.text += " " + s.text;
    else result.push({ ...s });
  }
  return result;
}
export function prefix(
  turn: { speaker?: string | null; start?: number },
  style: string,
) {
  if (style === "transcripcion-texto") return "";
  const stamp =
    style === "transcripcion-tiempos" && turn.start !== undefined
      ? `[${clock(turn.start)}]`
      : "";
  return [stamp, turn.speaker].filter(Boolean).join(" ");
}
export function transcript(
  note: Note,
  style = "transcripcion",
  markdown = false,
) {
  return turns(note)
    .flatMap((t) =>
      t.text
        .split(/\r?\n/)
        .filter(Boolean)
        .map((line, i) => {
          const p = i === 0 ? prefix(t, style) : "";
          return p
            ? `${markdown ? "**" : ""}${p}:${markdown ? "**" : ""} ${line}`
            : line;
        }),
    )
    .join(markdown ? "\n\n" : "\n");
}
export function values(note: Note) {
  const date = dateValues(note.startedAt, note.timeZone || "UTC");
  const title = note.digest?.title.trim() || fallbackTitle(note.text, note.key);
  const summary = note.digest?.summary.trim() || "";
  let description =
    summary.split(/\n/)[0].match(/^.*?[.?!](?=\s|$)/)?.[0] ||
    summary.split(/\n/)[0];
  if (description.length > 200) {
    let out = "";
    for (const word of description.split(/\s+/)) {
      const next = out ? out + " " + word : word;
      if (next.length >= 200) break;
      out = next;
    }
    description = (out || description.slice(0, 199)) + "…";
  }
  const speakers = [
    ...new Set(
      note.segments.map((s) => s.speaker).filter((s): s is string => !!s),
    ),
  ];
  const duration = note.segments.at(-1)?.end;
  const tags = note.digest?.tags || [];
  const map: Record<string, string> = {
    titulo: title,
    descripcion: description || `Grabación del ${date.long}.`,
    resumen: summary,
    etiquetas: tags.join(", "),
    fecha: date.long,
    "fecha-iso": date.iso,
    dia: date.day,
    hablantes: speakers.join(", "),
    duracion: duration === undefined ? "" : clock(duration),
    segundos: duration === undefined ? "" : String(Math.round(duration)),
    clave: note.key,
    origen: decodeURIComponent(note.source.replace(/^file:\/\//, "")),
    audio: note.source,
  };
  return {
    title,
    tags,
    speakers,
    duration,
    date,
    inline: (token: string) =>
      token.startsWith("transcripcion") ? transcript(note) : map[token] || "",
  };
}
export function cleanBody(text: string) {
  const lines = text.split("\n");
  const keep = lines.map(() => true);
  for (let i = lines.length - 1; i >= 0; i--) {
    const heading = lines[i].match(/^(#{1,6})(?:\s|$)/);
    if (!heading) continue;
    if (!lines[i].replace(/^#+/, "").trim()) {
      keep[i] = false;
      continue;
    }
    let content = false;
    for (let j = i + 1; j < lines.length; j++) {
      const next = lines[j].match(/^(#{1,6})(?:\s|$)/);
      if (next && next[1].length <= heading[1].length) break;
      if (keep[j] && lines[j].trim()) content = true;
    }
    keep[i] = content;
  }
  return lines
    .filter((_, i) => keep[i])
    .join("\n")
    .replace(/\n[ \t]*\n(?:[ \t]*\n)+/g, "\n\n")
    .trim();
}
export function slug(text: string) {
  const words =
    text
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .match(/[a-z0-9]+/g) || [];
  let result = "";
  for (const word of words) {
    const next = result ? result + "-" + word : word;
    if (next.length > 60) {
      if (!result) result = word.slice(0, 60);
      break;
    }
    result = next;
  }
  return result || "nota";
}
export const quote = (text: string) =>
  JSON.stringify(text.split(/[\r\n\t]+/).join(" "));
export const linkText = (text: string) => text.replace(/([\[\]])/g, "\\$1");

function fallbackTitle(text: string, key: string) {
  const words = text.split(/\s+/).filter(Boolean);
  if (!words.length) return key;
  const taken: string[] = [];
  let length = 0;
  for (const word of words) {
    const next = length + (taken.length ? 1 : 0) + Array.from(word).length;
    if (next > 80) break;
    taken.push(word);
    length = next;
  }
  return taken.join(" ") + (taken.length < words.length ? "…" : "");
}
