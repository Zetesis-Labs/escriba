import { canonical, isObject, sha256, type Json } from "./json";
import { readVersion, type LibraryData, type Recording, type Transcript, type Version } from "./model";

export const PREVIEW_CHARACTERS = 400;
const chars = (value: string) => Array.from(value);
const take = (value: string, count: number) => chars(value).slice(0, count).join("");

function transcriptPreview(transcript: Transcript): string {
  if (transcript.text) return take(transcript.text, PREVIEW_CHARACTERS);
  let text = "";
  for (const segment of transcript.segments) {
    if (chars(text).length >= PREVIEW_CHARACTERS) break;
    if (text) text += "\n";
    text += take(segment.text, PREVIEW_CHARACTERS - chars(text).length);
  }
  return text;
}
export function summaryDescription(summary: string): string | null {
  const trimmed = summary.trim();
  if (!trimmed) return null;
  const line = trimmed.split("\n")[0] ?? trimmed;
  let sentence = line;
  const items = chars(line);
  for (let index = 0; index < items.length; index++) {
    const character = items[index]!;
    const next = items[index + 1];
    if (".?!".includes(character) && (next === undefined || /\s/.test(next))) {
      sentence = items.slice(0, index + 1).join("");
      break;
    }
  }
  if (chars(sentence).length <= 200) return sentence;
  let taken = "";
  for (const word of sentence.split(/\s+/).filter(Boolean)) {
    const length = chars(taken).length + (taken ? 1 : 0) + chars(word).length;
    if (length >= 200) break;
    taken += (taken ? " " : "") + word;
  }
  if (!taken) taken = take(sentence, 199);
  return `${taken}…`;
}
export const revision = (version: Version) => sha256(canonical(version));

export function previewVersion(version: Version): Version {
  const transcript = version.transcript ?? undefined;
  const duration = transcript ? (transcript.duration ?? transcript.segments.at(-1)?.end ?? null) : null;
  const language = transcript?.language ?? null;
  let digest = version.digest;
  if (isObject(digest)) {
    const preview: Record<string, Json> = {};
    for (const key of ["title", "description", "tags"]) if (key in digest) preview[key] = digest[key] as Json;
    if (typeof digest.summary === "string") preview.description = summaryDescription(digest.summary);
    digest = preview;
  }
  const { data: _data, inputs: _inputs, transcript: _transcript, digest: _digest, ...rest } = version;
  const extras: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(rest))
    if (!["id", "createdAt", "backend", "hasVoices", "recipeId"].includes(key)) extras[key] = value;
  const result: Record<string, unknown> = { id: version.id };
  for (const key of ["createdAt", "backend", "hasVoices", "recipeId"] as const)
    if (key in version) result[key] = version[key];
  if ("digest" in version) result.digest = digest;
  result.transcript = { text: transcript ? transcriptPreview(transcript) : "", segments: [], duration, language };
  result.revision = revision(version);
  if (typeof extras.title === "string") result.title = extras.title;
  return result as Version;
}
export function lightVersion(value: unknown): Version {
  return previewVersion(readVersion(value, "Versión guardada inválida"));
}
function selected(value: unknown, keys: readonly string[]): Record<string, Json> {
  const result: Record<string, Json> = {};
  if (isObject(value)) for (const key of keys) if (key in value) result[key] = value[key] as Json;
  return result;
}
export function lightPublication(publication: unknown): Record<string, Json> {
  const light = selected(publication, ["destinationId", "accountId", "provider", "error", "updatedAt"]);
  light.receipt = selected(isObject(publication) ? publication.receipt : undefined, ["state", "locator", "url", "folder"]);
  return light;
}
export const fingerprint = (program: string) => sha256(program).slice(0, 12);
function withoutProgram(items: Json, field: string, renamed: string): Json {
  if (!Array.isArray(items)) return items;
  return items.map((item) => {
    if (!isObject(item)) return item;
    const { [field]: program, ...light } = item;
    return typeof program === "string" ? { ...light, [renamed]: fingerprint(program) } : light;
  });
}
export function lightRecording(record: Recording): Record<string, Json> {
  const { versions, publications, ...rest } = record;
  const light: Record<string, Json> = { ...(rest as Record<string, Json>) };
  light.versions = Array.isArray(versions) ? (versions.map((version) => previewVersion(version)) as Json[]) : [];
  if (Array.isArray(publications)) light.publications = publications.map(lightPublication);
  else if (publications === null) light.publications = null;
  return light;
}
export function typedLibrary(data: LibraryData): Record<string, Json> {
  const { recordings, settings, accounts, resolvers, recipes, destinations, providers, ...extra } = data;
  const result: Record<string, Json> = { ...(extra as Record<string, Json>) };
  result.recordings = recordings
    .filter((record) => record.status !== "discarded")
    .map((record) => {
      const { versions, ...fields } = record;
      return { ...(fields as Record<string, Json>), versions: (versions ?? []) as Json[] };
    });
  result.settings = settings as Record<string, Json>;
  result.accounts = accounts;
  result.resolvers = resolvers;
  result.recipes = withoutProgram(recipes, "bundle", "bundleFingerprint");
  result.destinations = withoutProgram(destinations, "program", "programFingerprint");
  result.providers = withoutProgram(providers, "program", "programFingerprint");
  return result;
}
