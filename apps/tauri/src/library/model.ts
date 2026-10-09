import type { Account, Destination, JSONObject, Publication, Recipe, Recording, Resolver, Snapshot, Transcript, Version, WatchedFolder } from "../types";

export const versionsInOrder = (recording: Recording) =>
  [...recording.versions].sort((a, b) => a.createdAt.localeCompare(b.createdAt));

export function currentVersion(recording: Recording): Version | undefined {
  const versions = versionsInOrder(recording);
  return versions.find((version) => version.id === recording.currentVersionId) ?? versions.at(-1);
}

export const transcriptDuration = (transcript: Transcript | undefined) =>
  transcript?.duration ?? transcript?.segments.at(-1)?.end ?? undefined;

export function originName(recording: Recording, folders: WatchedFolder[]) {
  const source = recording.source;
  const folder = folders
    .filter((candidate) => source === candidate.path || source.startsWith(candidate.path.endsWith("/") ? candidate.path : `${candidate.path}/`))
    .sort((a, b) => b.path.length - a.path.length)[0];
  return folder?.name ?? "Bandeja";
}

export function criteriaLabel(inputs: JSONObject | undefined) {
  if (!inputs) return "criterios desconocidos";
  const language = typeof inputs.language === "string" && inputs.language !== "auto" ? inputs.language.toUpperCase() : "idioma automático";
  const speakers =
    inputs.diarize === true ? (typeof inputs.speakers === "number" ? `${inputs.speakers} hablantes` : "hablantes automáticos") : "sin hablantes";
  return `${language} · ${speakers}`;
}

const versionDate = new Intl.DateTimeFormat("es-ES", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

export function versionTitle(version: Version, number: number, recipes: Recipe[], resolvers: Resolver[]) {
  const recipe = recipes.find((item) => item.id === version.recipeId)?.name;
  const label = [`v${number}`, recipe, version.backend === "correccion" ? "corrección" : criteriaLabel(version.inputs)]
    .filter(Boolean)
    .join(" · ");
  const backend = resolvers.find((item) => item.id === version.backend)?.name ?? version.backend;
  return `${label} · ${backend} · ${versionDate.format(new Date(version.createdAt))}`;
}

export function currentVersionLabel(recording: Recording) {
  const versions = versionsInOrder(recording);
  const current = currentVersion(recording);
  if (!current) return "Versiones";
  return `v${versions.indexOf(current) + 1} de ${versions.length}`;
}

export const isPublished = (publication: Publication) => !publication.error && Object.keys(publication.receipt ?? {}).length > 0;

export function liveDestinations(destinations: Destination[], accounts: Account[]) {
  return destinations.filter(
    (destination) => destination.enabled && accounts.some((account) => account.id === destination.account && account.enabled),
  );
}

export function publishedNames(recording: Recording) {
  return recording.publications.filter(isPublished).map((publication) => publication.name);
}

export function libraryRecordings(data: Snapshot) {
  return data.recordings.filter((recording) => recording.status !== "discarded").sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export const providerLabel = (provider: string) => (provider === "notion" ? "Notion" : provider === "okf" ? "OKF" : provider);
