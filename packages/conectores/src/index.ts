import { z } from "zod";
import type { Request, Host, Result } from "./types.js";
import type { Configuration, ProviderManifest, ConnectorEditorResult } from "./protocol.js";
import { describeBuiltin, actionBuiltin, builtinProblem, notionDefaultConfiguration, okfDefaultConfiguration } from "./editor.js";
import { runOKF, okfConfig, okfSchema, standardDocuments } from "./okf.js";
import {
  runNotion,
  notionConfig,
  notionSchema,
  notionProblem,
} from "./notion.js";
export * from "./types.js";
export * from "./protocol.js";
export { notionConfig, notionSchema, notionProblem, suggestedColumns } from "./notion.js";
export { okfConfig, okfSchema, standardDocuments } from "./okf.js";
const inputSchema = z.object({
  key: z.string(),
  text: z.string(),
  startedAt: z.string(),
  segments: z.array(
    z.object({
      start: z.number(),
      end: z.number(),
      speaker: z.string().nullable().optional(),
      text: z.string(),
    }),
  ),
  digest: z
    .object({
      title: z.string(),
      summary: z.string(),
      tags: z.array(z.string()),
    })
    .nullable()
    .optional(),
  source: z.string(),
  timeZone: z.string(),
});
export const builtinProviders: ProviderManifest[] = [
  { id: "notion", name: "Notion", capability: "http", origin: "https://api.notion.com", allowedHeaders: ["content-type", "accept", "notion-version"], credential: { label: "Token de la integración", header: "Authorization", prefix: "Bearer ", help: "En Notion: Ajustes → Conexiones → nueva conexión con «Token de acceso»." }, defaultConfiguration: notionDefaultConfiguration, connectAction: "refresh-sources", configurationSchema: z.toJSONSchema(notionSchema) as Configuration, autoPublishLabel: "Publicar cada transcripción nueva", removalMessage: "Se borran su configuración y su token de Notion; tendrías que volver a pegarlo. Las páginas ya publicadas siguen en Notion." },
  { id: "okf", name: "OKF", capability: "folder", allowedHeaders: [], defaultConfiguration: okfDefaultConfiguration, configurationSchema: z.toJSONSchema(okfSchema) as Configuration, autoPublishLabel: "Exportar cada transcripción nueva", removalMessage: "Se borra su configuración. Los ficheros ya escritos siguen en la carpeta." },
];
export interface ConfigurationSchema {
  parse(value: unknown): unknown;
  safeParse(value: unknown): { success: true; data: unknown } | { success: false; error: { issues: Array<{ path: PropertyKey[]; message: string }> } };
  toJSONSchema(): unknown;
}
export interface ProviderDefinition {
  manifest: ProviderManifest;
  configurationSchema: ConfigurationSchema;
  describe: (configuration: Configuration, state: Configuration) => ConnectorEditorResult | Promise<ConnectorEditorResult>;
  action?: (configuration: Configuration, state: Configuration, action: string, value: unknown, host?: Host) => ConnectorEditorResult | Promise<ConnectorEditorResult>;
  run?: (request: Request, host?: Host) => Result | Promise<Result>;
}
const headerName = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
function safeText(value: string, label: string) {
  if (!value.trim() || /[\r\n\0]/.test(value)) throw Error(`${label} no válido`);
}
export function defineProvider(definition: ProviderDefinition): ProviderDefinition {
  const { manifest } = definition;
  if (!/^[a-z][a-z0-9-]*$/.test(manifest.id) || manifest.id === "notion" || manifest.id === "okf") throw Error(`ID de proveedor no válido o reservado: ${manifest.id}`);
  safeText(manifest.name, "Nombre de proveedor");
  if (manifest.description) safeText(manifest.description, "Descripción de proveedor");
  if (manifest.connectAction) safeText(manifest.connectAction, "Acción de conexión");
  if (manifest.capability === "http") {
    if (!manifest.origin) throw Error("El proveedor HTTP necesita un origen");
    let origin: URL;
    try { origin = new URL(manifest.origin); } catch { throw Error("El proveedor HTTP necesita un origen válido"); }
    if (!["https:", "http:"].includes(origin.protocol) || origin.origin !== manifest.origin || origin.username || origin.password) throw Error("El proveedor HTTP necesita un origen sin ruta ni credenciales");
    if (origin.protocol === "http:" && !["127.0.0.1", "[::1]"].includes(origin.hostname)) throw Error("El origen HTTP externo requiere HTTPS");
  }
  if (manifest.capability === "folder" && (manifest.origin || manifest.credential)) throw Error("Un proveedor de carpeta no puede declarar acceso HTTP");
  const headers = new Set<string>();
  for (const header of manifest.allowedHeaders) {
    if (!headerName.test(header)) throw Error(`Cabecera no válida: ${header}`);
    const normalized = header.toLowerCase();
    if (headers.has(normalized)) throw Error(`Cabecera repetida: ${header}`);
    headers.add(normalized);
  }
  if (manifest.credential) {
    safeText(manifest.credential.label, "Nombre de credencial");
    if (!headerName.test(manifest.credential.header)) throw Error("Cabecera de credencial no válida");
    if (headers.has(manifest.credential.header.toLowerCase())) throw Error("La cabecera de credencial se inyecta separadamente");
    if (manifest.credential.prefix && /[\r\n\0]/.test(manifest.credential.prefix)) throw Error("Prefijo de credencial no válido");
  }
  definition.configurationSchema.parse(manifest.defaultConfiguration);
  definition.configurationSchema.toJSONSchema();
  return definition;
}
export async function run(request: Request, host?: Host): Promise<Result> {
  if (request.operation === "describe" || request.operation === "action") {
    const provider = request.provider || "";
    if (!builtinProviders.some((entry) => entry.id === provider)) throw Error(`Proveedor desconocido: ${provider}`);
    const config = (request.config || builtinProviders.find((entry) => entry.id === provider)?.defaultConfiguration || {}) as Configuration;
    const state = (request.state || {}) as Configuration;
    const preview = (id: string, configuration: Configuration) => run({ operation: "preview", provider: id, config: configuration });
    return request.operation === "describe" ? describeBuiltin(provider, config, state, preview) : actionBuiltin(provider, config, state, request.action || "", request.value, preview, host);
  }

  if (request.operation === "manifest") return { providers: builtinProviders.map((provider) => ({ ...provider, inputSchema: z.toJSONSchema(inputSchema) })) };
  if (request.operation === "preview" && !request.note) {
    const now = request.now || new Date().toISOString();
    request = {
      ...request,
      note: {
        key: "ejemplo",
        startedAt: new Date(new Date(now).getTime() - 7200000).toISOString(),
        text: "¿Cómo vamos con el lanzamiento del jueves?\nLa migración no llega; propongo moverla una semana.\nVale, y avisamos a soporte hoy mismo.",
        segments: [
          {
            start: 0,
            end: 8,
            speaker: "Ana",
            text: "¿Cómo vamos con el lanzamiento del jueves?",
          },
          {
            start: 8,
            end: 21,
            speaker: "Luis",
            text: "La migración no llega; propongo moverla una semana.",
          },
          {
            start: 21,
            end: 29,
            speaker: "Ana",
            text: "Vale, y avisamos a soporte hoy mismo.",
          },
        ],
        digest: {
          title: "Lanzamiento del jueves",
          summary:
            "Ana y Luis repasan el lanzamiento del jueves. Acuerdan mover la migración una semana y avisar hoy a soporte.",
          tags: ["lanzamiento", "migración"],
        },
        source: "file:///Notas%20de%20voz/Reunion%20del%20lanzamiento.m4a",
        timeZone: "UTC",
      },
    };
  }
  if (request.operation === "preview" && !host)
    host = {
      fetch: async () => {
        throw Error("Vista previa sin red");
      },
      files: {
        snapshot: async () => ({}),
        apply: async () => {
          throw Error("Vista previa sin escritura");
        },
      },
      audio: async () => null,
      checkpoint: async () => {
        throw Error("Vista previa sin escritura");
      },
    };
  const provider = request.provider;
  if (request.previous?.provider && request.previous.provider !== provider)
    throw Error("El recibo pertenece a otro proveedor");
  if (
    request.previous?.key &&
    request.note &&
    request.previous.key !== request.note.key
  )
    throw Error("El recibo pertenece a otra nota");
  if (provider !== "okf" && provider !== "notion")
    throw Error("Proveedor desconocido");
  if (request.operation === "template")
    return {
      configuration:
        provider === "okf"
          ? {
              folder:
                typeof request.config?.folder === "string"
                  ? request.config.folder
                  : "",
              documents: standardDocuments(),
            }
          : {
              source: { id: "", title: "", databaseTitle: "", properties: [] },
              columns: {},
              body: "{{transcripcion}}",
            },
    };
  if (request.operation === "validate") {
    try {
      const builtin = builtinProblem(provider, (request.config || {}) as Configuration);
      const config =
        provider === "okf"
          ? okfConfig(request.config)
          : notionConfig(request.config);
      let problem =
        provider === "notion" ? notionProblem(notionConfig(config)) : undefined;
      if (provider === "okf") {
        const docs = okfConfig(config).documents;
        for (let i = 0; i < docs.length; i++)
          for (let j = i + 1; j < docs.length; j++)
            if (
              docs[i].path.trim().replace(/^\/+|\/+$/g, "") ===
              docs[j].path.trim().replace(/^\/+|\/+$/g, "")
            )
              problem = `«${docs[i].name}» y «${docs[j].name}» escriben en la misma ruta.`;
        for (const doc of okfConfig(config).documents)
          if (
            !doc.properties.find((p) => p.key.trim() === "type")?.value.trim()
          )
            problem = `«${doc.name}» necesita un valor en type: OKF lo exige.`;
      }
      problem ||= builtin;
      return {
        valid: !problem,
        ...(problem ? { problem } : {}),
        inputSchema: z.toJSONSchema(inputSchema),
      };
    } catch (error) {
      return {
        valid: false,
        problem: error instanceof Error ? error.message : String(error),
      };
    }
  }
  if (request.operation === "migrate") {
    const configuration =
      provider === "okf"
        ? okfConfig(request.config)
        : notionConfig(request.config);
    const account =
      provider === "okf"
        ? {
            capability: "folder",
            folder: okfConfig(configuration).folder,
            allowedHeaders: [],
          }
        : {
            capability: "http",
            origin: "https://api.notion.com",
            allowedHeaders: ["content-type", "accept", "notion-version"],
          };
    const migrated =
      provider === "okf" && request.previous && host
        ? await runOKF(request, host)
        : {};
    return { ...migrated, configuration, account };
  }
  if (request.operation === "discover" && provider === "okf")
    return {
      resources: okfConfig(request.config).documents.map((doc) => ({
        id: doc.id,
        name: doc.name,
        description: doc.path,
      })),
    };
  if (!host) throw Error("Falta el host de capacidades");
  return provider === "okf" ? runOKF(request, host) : runNotion(request, host);
}
export interface DestinationOptions {
  id: string;
  name: string;
  account: string;
  configuration: Record<string, unknown>;
  inputSchema?: ConfigurationSchema;
  description?: string;
  prepare?: (
    input: unknown,
    request: Request,
  ) => Request["note"] | Promise<Request["note"]>;
}
export interface Destination extends DestinationOptions {
  provider: string;
}
export function defineNotionDestination(
  options: DestinationOptions,
): Destination {
  return { ...options, provider: "notion" };
}
export function defineOKFDestination(options: DestinationOptions): Destination {
  return { ...options, provider: "okf" };
}
export function createProgram(destinations: Destination[], providers: ProviderDefinition[] = []) {
  const byProvider = new Map<string, ProviderDefinition>();
  for (const provider of providers) {
    defineProvider(provider);
    if (byProvider.has(provider.manifest.id)) throw Error(`Proveedor repetido: ${provider.manifest.id}`);
    byProvider.set(provider.manifest.id, provider);
  }
  const byID = new Map<string, Destination>();
  for (const d of destinations) {
    if (!d.id || byID.has(d.id))
      throw Error(`ID de destino vacío o repetido: ${d.id}`);
    if (!builtinProviders.some((provider) => provider.id === d.provider) && !byProvider.has(d.provider)) throw Error(`Proveedor desconocido: ${d.provider}`);
    byID.set(d.id, d);
  }
  return {
    inspect() {
      return {
        providers: [...builtinProviders, ...providers.map((provider) => ({ ...provider.manifest, configurationSchema: provider.configurationSchema.toJSONSchema() as Configuration }))],
        destinations: destinations.map((d) => ({
          id: d.id,
          name: d.name,
          provider: d.provider,
          account: d.account,
          configuration: d.configuration,
          inputSchema: d.inputSchema ? d.inputSchema.toJSONSchema() : z.toJSONSchema(inputSchema),
          ...(d.description ? { description: d.description } : {}),
        })),
      };
    },
    async run(request: Request, host?: Host): Promise<Result> {
      const custom = byProvider.get(request.provider || "");
      if (request.operation === "manifest") return { providers: [...builtinProviders, ...providers.map((provider) => ({ ...provider.manifest, configurationSchema: provider.configurationSchema.toJSONSchema() as Configuration }))] };
      if (request.operation === "describe" || request.operation === "action" || request.operation === "validate" || request.operation === "template" || request.operation === "discover") {
        if (custom) {
          const config = (request.config || custom.manifest.defaultConfiguration) as Configuration;
          const state = (request.state || {}) as Configuration;
          if (request.operation === "describe") return custom.describe(config, state);
          if (request.operation === "action") {
            if (!custom.action) throw Error(`El proveedor ${custom.manifest.id} no declara acciones`);
            return custom.action(config, state, request.action || "", request.value, host);
          }
          if (request.operation === "validate") {
            const parsed = custom.configurationSchema.safeParse(config);
            return parsed.success ? { valid: true } : { valid: false, problem: parsed.error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`).join("; ") };
          }
          if (request.operation === "template") return { configuration: custom.manifest.defaultConfiguration };
          if (!custom.run) throw Error(`El proveedor ${custom.manifest.id} no implementa ${request.operation}`);
          return custom.run(request, host);
        }
        if (request.provider) return run(request, host);
      }
      if (custom && !request.destination) {
        if (!custom.run) throw Error(`El proveedor ${custom.manifest.id} no implementa ${request.operation}`);
        return custom.run({ ...request, config: request.config || custom.manifest.defaultConfiguration }, host);
      }
      const d = byID.get(request.destination || "");
      if (!d) throw Error(`Destino desconocido: ${request.destination}`);
      let note = request.note;
      if (request.operation === "publish" || request.operation === "preview") {
        const input = (d.inputSchema || inputSchema).parse(
          request.input ?? request.note,
        );
        note = d.prepare ? await d.prepare(input, request) : request.note;
      }
      const provider = byProvider.get(d.provider);
      const delegated = { ...request, note, provider: d.provider, config: request.config || d.configuration };
      if (provider) {
        if (!provider.run) throw Error(`El proveedor ${d.provider} no implementa ${request.operation}`);
        return provider.run(delegated, host);
      }
      return run(delegated, host);
    },
  };
}
