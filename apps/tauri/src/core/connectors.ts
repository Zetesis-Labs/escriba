import { notionConfig, notionProblem, notionSchema, standardDocuments, suggestedColumns } from "@escriba/conectores";
import { abbreviatedPath } from "./settings";
import type { Account, Destination } from "../types";

export type ConnectorKind = "notion" | "okf";
export const isAppConnector = (destination: Destination) => !destination.program && !destination.programFingerprint && destination.id === destination.account;
export interface NotionSource {
  id: string;
  title: string;
  databaseTitle: string;
  properties: { name: string; type: string }[];
}
export interface NotionConfiguration {
  source: NotionSource;
  columns: Record<string, string>;
  body: string;
}
export interface OKFProperty {
  id?: string;
  key: string;
  value: string;
}
export interface OKFDocument {
  id: string;
  name: string;
  path: string;
  properties: OKFProperty[];
  body: string;
}
export interface OKFConfiguration {
  folder: string;
  documents: OKFDocument[];
}
export type ConnectorConfiguration = NotionConfiguration | OKFConfiguration;
export type ConnectorDestination<C extends ConnectorConfiguration = ConnectorConfiguration, K extends ConnectorKind = ConnectorKind> = Omit<Destination, "configuration" | "provider"> & { provider: K; configuration: C };

export function nextConnectorName(kind: ConnectorKind, names: string[]): string {
  const base = kind === "notion" ? "Notion" : "OKF";
  if (!names.includes(base)) return base;
  for (let number = 2; ; number++) {
    const name = `${base} ${number}`;
    if (!names.includes(name)) return name;
  }
}

export function makeConnector(kind: "notion", id: string, name: string): { account: Account; destination: ConnectorDestination<NotionConfiguration, "notion"> };
export function makeConnector(kind: "okf", id: string, name: string): { account: Account; destination: ConnectorDestination<OKFConfiguration, "okf"> };
export function makeConnector(kind: ConnectorKind, id: string, name: string): { account: Account; destination: ConnectorDestination<NotionConfiguration, "notion"> | ConnectorDestination<OKFConfiguration, "okf"> };
export function makeConnector(kind: ConnectorKind, id: string, name: string) {
  const account: Account = { id, name, provider: kind, enabled: true, ...(kind === "notion" ? { origin: "https://api.notion.com" } : { folder: "" }) };
  if (kind === "notion") {
    const configuration: NotionConfiguration = { source: { id: "", title: "", databaseTitle: "", properties: [] }, columns: {}, body: "{{transcripcion}}" };
    return { account, destination: { id, name, provider: kind, account: id, enabled: false, configuration } };
  }
  const configuration: OKFConfiguration = { folder: "", documents: standardDocuments() };
  return { account, destination: { id, name, provider: kind, account: id, enabled: false, configuration } };
}

export function notionConfiguration(raw: unknown): NotionConfiguration {
  const parsed = notionSchema.safeParse(raw);
  if (parsed.success) return notionConfig(parsed.data);
  const input = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const source = "source" in input ? input.source : undefined;
  const object = source && typeof source === "object" && !Array.isArray(source) ? source : {};
  const rawProperties = "properties" in object ? object.properties : undefined;
  const properties = Array.isArray(rawProperties)
    ? rawProperties.filter((item): item is { name: string; type: string } => !!item && typeof item === "object" && !Array.isArray(item) && "name" in item && "type" in item && typeof item.name === "string" && typeof item.type === "string")
    : [];
  const rawColumns = "columns" in input ? input.columns : undefined;
  const columns = rawColumns && typeof rawColumns === "object" && !Array.isArray(rawColumns)
    ? Object.fromEntries(Object.entries(rawColumns).filter((entry): entry is [string, string] => typeof entry[1] === "string"))
    : {};
  return {
    source: {
      id: "id" in object && typeof object.id === "string" ? object.id : "",
      title: "title" in object && typeof object.title === "string" ? object.title : "",
      databaseTitle: "databaseTitle" in object && typeof object.databaseTitle === "string" ? object.databaseTitle : "",
      properties,
    },
    columns,
    body: "body" in input && typeof input.body === "string" ? input.body : "{{transcripcion}}",
  };
}

export function okfConfiguration(raw: unknown): OKFConfiguration {
  const input = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const documents = "documents" in input && Array.isArray(input.documents) ? input.documents : standardDocuments();
  return {
    folder: "folder" in input && typeof input.folder === "string" ? input.folder : "",
    documents: documents.flatMap((item) => {
      if (!item || typeof item !== "object" || Array.isArray(item) || typeof item.id !== "string") return [];
      const rawProperties: unknown[] = Array.isArray(item.properties) ? item.properties : [];
      return [{
        id: item.id,
        name: typeof item.name === "string" ? item.name : "",
        path: typeof item.path === "string" ? item.path : "",
        body: typeof item.body === "string" ? item.body : "",
        properties: rawProperties.flatMap((property) => {
          if (!property || typeof property !== "object" || Array.isArray(property) || !("key" in property) || !("value" in property) || typeof property.key !== "string" || typeof property.value !== "string") return [];
          return [{ ...("id" in property && typeof property.id === "string" ? { id: property.id } : {}), key: property.key, value: property.value }];
        }),
      }];
    }),
  };
}

export function writableColumns(source: Pick<NotionSource, "properties">) {
  const writable = source.properties.filter((property) => ["title", "rich_text", "multi_select", "select", "date", "number", "url"].includes(property.type));
  return [...writable.filter((property) => property.type === "title"), ...writable.filter((property) => property.type !== "title")];
}

export function chooseNotionSource(current: NotionConfiguration, source: NotionSource): NotionConfiguration {
  return {
    source,
    columns: suggestedColumns(source, current.source.id === source.id ? current.columns : {}),
    body: current.body,
  };
}

export function okfProblem(config: OKFConfiguration): string | null {
  if (!config.folder.trim()) return "Elige la carpeta donde guardar las notas.";
  if (!config.documents.length) return "Añade al menos un documento.";
  for (const document of config.documents) {
    if (!document.properties.find((property) => property.key.trim() === "type")?.value.trim())
      return `«${document.name}» necesita un valor en type: OKF lo exige.`;
  }
  const normalized = (path: string) => path.trim().replace(/^\/+|\/+$/g, "");
  for (let index = 0; index < config.documents.length; index++) {
    const first = config.documents[index];
    const twin = config.documents.slice(index + 1).find((document) => normalized(document.path) === normalized(first.path));
    if (twin) return `«${first.name}» y «${twin.name}» escriben en la misma ruta.`;
  }
  return null;
}

export function connectorProblem(account: Account, destination: { provider: ConnectorKind; configuration: unknown }, enteredToken = ""): string | null {
  if (destination.provider === "okf") return okfProblem(okfConfiguration(destination.configuration));
  if (!account.hasCredential && !enteredToken.trim()) return "Pega el token de tu integración de Notion.";
  const config = notionConfiguration(destination.configuration);
  if (!config.source.id) return "Elige la base donde guardar.";
  return notionProblem(config) ?? null;
}

export function connectorSubtitle(destination: { provider: ConnectorKind; configuration: unknown }, home: string | null): string {
  if (destination.provider === "notion") {
    const source = notionConfiguration(destination.configuration).source;
    if (!source.id) return "Sin base elegida";
    return source.databaseTitle === source.title || !source.title ? source.databaseTitle : `${source.databaseTitle} › ${source.title}`;
  }
  const config = okfConfiguration(destination.configuration);
  return okfProblem(config) ? "Sin carpeta elegida" : abbreviatedPath(config.folder, home);
}

export function newOKFDocument(number: number, id: string): OKFDocument {
  return { id, name: `Documento ${number}`, path: "documentos/{{dia}}-{{titulo}}.md", properties: [{ key: "type", value: "Documento" }, { key: "title", value: "{{titulo}}" }], body: "{{resumen}}" };
}

export function removeOKFProperty(document: OKFDocument, index: number): OKFDocument {
  const property = document.properties[index];
  const firstType = document.properties.findIndex((candidate) => candidate.key.trim() === "type");
  if (!property || index === firstType) return document;
  return { ...document, properties: document.properties.filter((_, candidate) => candidate !== index) };
}

export function removalText(kind: ConnectorKind): string {
  return kind === "notion"
    ? "Se borran su configuración y su token de Notion; tendrías que volver a pegarlo. Las páginas ya publicadas siguen en Notion."
    : "Se borra su configuración. Los ficheros ya escritos siguen en la carpeta.";
}
