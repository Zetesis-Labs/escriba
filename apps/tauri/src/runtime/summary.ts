import type { Digest } from "../types";
import { aborted, object, text, type RuntimeHost, request } from "./contracts";
function chunks(input: string, limit: number): string[] {
  const parts: string[] = [];
  let pending = input.trim();
  while (pending.length > limit) {
    let split = pending.lastIndexOf("\n", limit);
    if (split < limit / 2) split = pending.lastIndexOf(" ", limit);
    if (split < limit / 2) split = limit;
    parts.push(pending.slice(0, split).trim());
    pending = pending.slice(split).trim();
  }
  if (pending) parts.push(pending);
  return parts;
}
function digest(value: unknown): Digest {
  const raw = object(value);
  const title = typeof raw.title === "string" ? raw.title.trim() : "";
  const summary = typeof raw.summary === "string" ? raw.summary.trim() : "";
  const tags = Array.isArray(raw.tags)
    ? raw.tags.filter((v): v is string => typeof v === "string")
    : [];
  if (!title && !summary) throw Error("El modelo devolvió un resumen vacío");
  return { title, summary, tags };
}
export async function summarizeText(
  host: RuntimeHost,
  input: string,
  resolverId: string,
  options: {
    prompt?: string;
    language?: string | null;
    capacity?: number;
    signal?: AbortSignal;
  } = {},
): Promise<Digest> {
  if (!input.trim()) throw Error("No hay texto que resumir");
  const limit = options.capacity ?? 3500;
  const instructions = [
    options.prompt?.trim() ||
      "Resume la grabación con fidelidad. Devuelve título, resumen y etiquetas. No inventes hechos.",
    `Idioma de la respuesta: ${options.language || "el del texto"}.`,
  ].join("\n");
  let pieces = chunks(input, limit);
  for (let round = 0; round < 8; round++) {
    const results: Digest[] = [];
    for (const piece of pieces) {
      aborted(options.signal);
      results.push(
        digest(
          await request(host, "summarize", {
            resolverId,
            instructions,
            prompt: round
              ? `Integra estos resúmenes parciales sin perder decisiones ni repetir información:\n${piece}`
              : piece,
          }),
        ),
      );
      aborted(options.signal);
    }
    if (results.length === 1) return results[0];
    const joined = results
      .map((r) => `${r.title}\n${r.summary}\nEtiquetas: ${r.tags.join(", ")}`)
      .join("\n\n");
    const next = chunks(joined, limit);
    if (
      round > 0 &&
      next.length >= pieces.length &&
      joined.length >= pieces.join("").length
    )
      throw Error(
        "Los resúmenes parciales no se reducen; usa otro modelo o un prompt más breve",
      );
    pieces = next;
  }
  throw Error("Se alcanzó el límite de reducción del resumen");
}
