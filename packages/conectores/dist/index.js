import { z } from "zod";
import { runOKF, okfConfig, okfSchema, standardDocuments } from "./okf.js";
import { runNotion, notionConfig, notionSchema, notionProblem, } from "./notion.js";
export * from "./types.js";
export { notionConfig, notionSchema, notionProblem, suggestedColumns } from "./notion.js";
export { okfConfig, okfSchema, standardDocuments } from "./okf.js";
const inputSchema = z.object({
    key: z.string(),
    text: z.string(),
    startedAt: z.string(),
    segments: z.array(z.object({
        start: z.number(),
        end: z.number(),
        speaker: z.string().nullable().optional(),
        text: z.string(),
    })),
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
export async function run(request, host) {
    if (request.operation === "manifest")
        return {
            providers: [
                {
                    id: "notion",
                    name: "Notion",
                    capability: "http",
                    origin: "https://api.notion.com",
                    allowedHeaders: ["content-type", "accept", "notion-version"],
                    configurationSchema: z.toJSONSchema(notionSchema),
                    inputSchema: z.toJSONSchema(inputSchema),
                },
                {
                    id: "okf",
                    name: "Open Knowledge Format",
                    capability: "folder",
                    allowedHeaders: [],
                    configurationSchema: z.toJSONSchema(okfSchema),
                    inputSchema: z.toJSONSchema(inputSchema),
                },
            ],
        };
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
                    summary: "Ana y Luis repasan el lanzamiento del jueves. Acuerdan mover la migración una semana y avisar hoy a soporte.",
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
    if (request.previous?.key &&
        request.note &&
        request.previous.key !== request.note.key)
        throw Error("El recibo pertenece a otra nota");
    if (provider !== "okf" && provider !== "notion")
        throw Error("Proveedor desconocido");
    if (request.operation === "template")
        return {
            configuration: provider === "okf"
                ? {
                    folder: typeof request.config?.folder === "string"
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
            const config = provider === "okf"
                ? okfConfig(request.config)
                : notionConfig(request.config);
            let problem = provider === "notion" ? notionProblem(notionConfig(config)) : undefined;
            if (provider === "okf") {
                const docs = okfConfig(config).documents;
                for (let i = 0; i < docs.length; i++)
                    for (let j = i + 1; j < docs.length; j++)
                        if (docs[i].path.trim().replace(/^\/+|\/+$/g, "") ===
                            docs[j].path.trim().replace(/^\/+|\/+$/g, ""))
                            problem = `«${docs[i].name}» y «${docs[j].name}» escriben en la misma ruta.`;
                for (const doc of okfConfig(config).documents)
                    if (!doc.properties.find((p) => p.key.trim() === "type")?.value.trim())
                        problem = `«${doc.name}» necesita un valor en type: OKF lo exige.`;
            }
            return {
                valid: !problem,
                ...(problem ? { problem } : {}),
                inputSchema: z.toJSONSchema(inputSchema),
            };
        }
        catch (error) {
            return {
                valid: false,
                problem: error instanceof Error ? error.message : String(error),
            };
        }
    }
    if (request.operation === "migrate") {
        const configuration = provider === "okf"
            ? okfConfig(request.config)
            : notionConfig(request.config);
        const account = provider === "okf"
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
        const migrated = provider === "okf" && request.previous && host
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
    if (!host)
        throw Error("Falta el host de capacidades");
    return provider === "okf" ? runOKF(request, host) : runNotion(request, host);
}
export function defineNotionDestination(options) {
    return { ...options, provider: "notion" };
}
export function defineOKFDestination(options) {
    return { ...options, provider: "okf" };
}
export function createProgram(destinations) {
    const byID = new Map();
    for (const d of destinations) {
        if (!d.id || byID.has(d.id))
            throw Error(`ID de destino vacío o repetido: ${d.id}`);
        byID.set(d.id, d);
    }
    return {
        inspect() {
            return {
                destinations: destinations.map((d) => ({
                    id: d.id,
                    name: d.name,
                    provider: d.provider,
                    account: d.account,
                    configuration: d.configuration,
                    inputSchema: z.toJSONSchema(d.inputSchema || inputSchema),
                    ...(d.description ? { description: d.description } : {}),
                })),
            };
        },
        async run(request, host) {
            const d = byID.get(request.destination || "");
            if (!d)
                throw Error(`Destino desconocido: ${request.destination}`);
            let note = request.note;
            if (request.operation === "publish" || request.operation === "preview") {
                const input = (d.inputSchema || inputSchema).parse(request.input ?? request.note);
                note = d.prepare ? await d.prepare(input, request) : request.note;
            }
            return run({ ...request, note, provider: d.provider, config: d.configuration }, host);
        },
    };
}
