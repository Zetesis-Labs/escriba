import { Client } from "@notionhq/client";
import { z } from "zod";
import { render, sole, values, turns, prefix } from "./templates.js";
export const notionSchema = z.object({
    source: z.object({
        id: z.string().min(1),
        title: z.string().default(""),
        databaseTitle: z.string().default(""),
        properties: z.array(z.object({ name: z.string(), type: z.string() })),
    }),
    columns: z.record(z.string(), z.string()).optional(),
    body: z.string().optional(),
    mapping: z.object({ byField: z.record(z.string(), z.string()) }).optional(),
    template: z
        .object({ blocks: z.array(z.record(z.string(), z.unknown())) })
        .optional(),
});
const fieldTokens = {
    title: "titulo",
    date: "fecha-iso",
    speakers: "hablantes",
    duration: "duracion",
    key: "clave",
    source: "origen",
    summary: "resumen",
    tags: "etiquetas",
};
const labels = {
    title: "Título",
    date: "Fecha de la grabación",
    speakers: "Hablantes",
    duration: "Duración (segundos)",
    key: "Clave de la grabación",
    source: "Fichero de origen",
    summary: "Resumen",
    tags: "Etiquetas",
};
export function notionConfig(raw) {
    const parsed = notionSchema.parse(raw);
    const columns = parsed.columns ||
        Object.fromEntries(Object.entries(parsed.mapping?.byField || {}).flatMap(([field, name]) => {
            const type = parsed.source.properties.find((p) => p.name === name)?.type;
            let token = fieldTokens[field];
            if (field === "duration" && type === "number")
                token = "segundos";
            if (field === "source" && type === "url")
                token = "audio";
            return type && token ? [[name, `{{${token}}}`]] : [];
        }));
    const body = parsed.body ??
        parsed.template?.blocks
            .map((block) => {
            const key = Object.keys(block)[0];
            const val = block[key];
            const value = typeof val === "object" && val !== null && "_0" in val
                ? String(val._0)
                : typeof val === "string"
                    ? val
                    : "";
            if (key === "text")
                return value;
            if (key === "heading")
                return "# " + value;
            if (key === "summary")
                return "{{resumen}}";
            if (key === "audio")
                return "{{audio}}";
            if (key === "transcript")
                return `{{${value === "plain" ? "transcripcion-texto" : value === "timestamps" ? "transcripcion-tiempos" : "transcripcion"}}}`;
            if (key === "field")
                return `**${labels[value]}:** {{${value === "date" ? "fecha" : fieldTokens[value]}}}`;
            return "";
        })
            .filter(Boolean)
            .join("\n\n") ??
        "{{transcripcion}}";
    return { source: parsed.source, columns, body };
}
export function suggestedColumns(source, existing = {}) {
    const specs = {
        title: { types: ["title"], hints: ["titulo", "nombre", "asunto"] },
        date: {
            types: ["date"],
            hints: ["fecha", "grabacion", "date", "dia", "momento"],
        },
        speakers: {
            types: ["multi_select", "rich_text"],
            hints: ["hablante", "speaker", "participante", "persona", "quien"],
        },
        duration: {
            types: ["number", "rich_text"],
            hints: ["duracion", "duration", "segundo", "length", "largo"],
        },
        key: {
            types: ["rich_text"],
            hints: ["clave", "key", "id", "identificador"],
        },
        source: {
            types: ["url", "rich_text"],
            hints: ["origen", "source", "fichero", "archivo", "ruta", "audio"],
        },
        summary: {
            types: ["rich_text"],
            hints: ["resumen", "summary", "sintesis", "abstract"],
        },
        tags: {
            types: ["multi_select", "rich_text"],
            hints: ["etiqueta", "tag", "tema", "categoria", "topic"],
        },
    };
    const chosen = {};
    const taken = new Set();
    const named = (name, field) => specs[field].hints.some((h) => name
        .normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "")
        .toLowerCase()
        .includes(h));
    for (const pass of [0, 1])
        for (const [field, spec] of Object.entries(specs)) {
            if (chosen[field])
                continue;
            const compatible = spec.types.flatMap((type) => source.properties.filter((p) => p.type === type));
            const property = compatible.find((p) => !taken.has(p.name) &&
                (pass === 0
                    ? named(p.name, field)
                    : !Object.keys(specs).some((other) => other !== field && named(p.name, other))));
            if (property) {
                chosen[field] = property.name;
                taken.add(property.name);
            }
        }
    const columns = notionConfig({
        source,
        mapping: { byField: chosen },
    }).columns;
    for (const [name, value] of Object.entries(existing))
        if (source.properties.some((p) => p.name === name &&
            [
                "title",
                "rich_text",
                "multi_select",
                "select",
                "date",
                "number",
                "url",
            ].includes(p.type)))
            columns[name] = value;
    return columns;
}
export function notionProblem(config) {
    const title = config.source.properties.find((p) => p.type === "title");
    if (!title)
        return `La base «${config.source.title}» no tiene propiedad de título.`;
    if (!config.columns[title.name]?.trim())
        return `Escribe qué va en «${title.name}», la columna del título.`;
}
const rt = (text, bold = false) => ({
    type: "text",
    text: { content: text },
    ...(bold ? { annotations: { bold: true } } : {}),
});
function runs(text) {
    const parts = text.split("**");
    return parts.length % 2 === 0
        ? [rt(text)]
        : parts.flatMap((p, i) => (p ? [rt(p, i % 2 === 1)] : []));
}
function chunks(text, limit = 2000) {
    const result = [];
    let current = "";
    for (const word of text.split(/\s+/).filter(Boolean)) {
        if ((current ? current + " " + word : word).length <= limit) {
            current = current ? current + " " + word : word;
            continue;
        }
        if (current) {
            result.push(current);
            current = "";
            limit = 2000;
        }
        let rest = word;
        while (rest.length > limit) {
            result.push(rest.slice(0, limit));
            rest = rest.slice(limit);
            limit = 2000;
        }
        current = rest;
    }
    if (current)
        result.push(current);
    return result;
}
function blocks(text, type = "paragraph", lead = "") {
    const result = [];
    for (const line of text.split(/\r?\n/).filter(Boolean)) {
        const rich = runs(line);
        const pieces = line.length + (result.length ? 0 : lead.length) > 2000
            ? chunks(line, 2000 - (result.length ? 0 : lead.length))
            : [line];
        for (const [i, piece] of pieces.entries()) {
            const prefixRun = result.length === 0 && lead ? [rt(lead, true)] : [];
            result.push({
                object: "block",
                type,
                [type]: {
                    rich_text: [
                        ...prefixRun,
                        ...(pieces.length === 1 ? rich : [rt(piece)]),
                    ],
                },
            });
        }
    }
    return result;
}
export function notionPayload(note, config, audio) {
    const v = values(note);
    const properties = {};
    for (const p of config.source.properties) {
        const template = config.columns[p.name];
        if (!template?.trim())
            continue;
        const token = sole(template);
        const text = render(template, v.inline).trim();
        switch (p.type) {
            case "title":
            case "rich_text":
                properties[p.name] = {
                    [p.type]: text ? [rt(text.slice(0, 2000))] : [],
                };
                break;
            case "multi_select":
                properties[p.name] = {
                    multi_select: (token === "etiquetas"
                        ? v.tags
                        : token === "hablantes"
                            ? v.speakers
                            : text.split(",").map((s) => s.trim()))
                        .filter(Boolean)
                        .map((name) => ({ name })),
                };
                break;
            case "select":
                properties[p.name] = { select: text ? { name: text } : null };
                break;
            case "date":
                if (token === "fecha-iso" || token === "fecha")
                    properties[p.name] = { date: { start: v.date.iso } };
                break;
            case "number": {
                const n = token === "segundos" || token === "duracion"
                    ? v.duration === undefined
                        ? null
                        : Math.round(v.duration)
                    : text
                        ? Number(text.replace(",", "."))
                        : null;
                properties[p.name] = {
                    number: n !== null && Number.isFinite(n) ? n : null,
                };
                break;
            }
            case "url":
                properties[p.name] = { url: text || null };
        }
    }
    const lines = config.body
        .split("\n")
        .flatMap((line) => {
        const token = sole(line);
        if (token?.startsWith("transcripcion"))
            return [
                {
                    blocks: turns(note).flatMap((t) => blocks(t.text, "paragraph", prefix(t, token) ? prefix(t, token) + ": " : "")),
                },
            ];
        if (token === "audio")
            return [
                {
                    blocks: audio
                        ? [
                            {
                                object: "block",
                                type: "audio",
                                audio: { type: "file_upload", file_upload: { id: audio } },
                            },
                        ]
                        : [],
                },
            ];
        return render(line, v.inline)
            .split("\n")
            .map((text) => {
            const heading = text.match(/^(#{1,6})(?:\s|$)(.*)/);
            if (heading)
                return {
                    level: heading[1].length,
                    blocks: blocks(heading[2].trim(), `heading_${Math.min(3, heading[1].length)}`),
                };
            return {
                blocks: /^[-*] /.test(text)
                    ? blocks(text.slice(2), "bulleted_list_item")
                    : blocks(text),
            };
        });
    });
    const kept = lines.map(() => true);
    for (let i = lines.length - 1; i >= 0; i--) {
        const level = lines[i].level;
        if (level === undefined)
            continue;
        let content = false;
        for (let j = i + 1; j < lines.length; j++) {
            const nested = lines[j].level;
            if (nested !== undefined && nested <= level)
                break;
            if (kept[j] && lines[j].blocks.length)
                content = true;
        }
        kept[i] = content && lines[i].blocks.length > 0;
    }
    const children = lines.flatMap((line, i) => (kept[i] ? line.blocks : []));
    return { properties, children };
}
function sdk(host) {
    return new Client({
        fetch: async (url, init) => {
            const method = (init?.method || "GET").toUpperCase();
            const path = new URL(String(url)).pathname;
            const repeatable = method === "GET" ||
                method === "DELETE" ||
                (method === "PATCH" && /^\/v1\/pages\/[^/]+$/.test(path)) ||
                (method === "POST" &&
                    (path === "/v1/search" ||
                        /^\/v1\/data_sources\/[^/]+\/query$/.test(path) ||
                        /^\/v1\/file_uploads\/[^/]+\/send$/.test(path)));
            for (let attempt = 0;; attempt++) {
                try {
                    return await host.fetch(url, init);
                }
                catch (error) {
                    if (!repeatable ||
                        attempt >= 4 ||
                        (init && "signal" in init && init.signal?.aborted))
                        throw error;
                    await new Promise((resolve) => setTimeout(resolve, 1000 * 2 ** attempt));
                }
            }
        },
        notionVersion: "2025-09-03",
        retry: { maxRetries: 4 },
        logger: () => { },
    });
}
async function upload(client, host) {
    const audio = await host.audio();
    if (!audio)
        throw Error("No se pudo leer el audio");
    const size = audio.data.size;
    const multi = size > 20 * 1024 * 1024;
    const partSize = 10 * 1024 * 1024;
    const created = await client.fileUploads.create({
        mode: multi ? "multi_part" : "single_part",
        filename: audio.filename,
        content_type: audio.data.type || "audio/mp4",
        ...(multi ? { number_of_parts: Math.ceil(size / partSize) } : {}),
    });
    if (multi) {
        for (let offset = 0, part = 1; offset < size; offset += partSize, part++)
            await client.fileUploads.send({
                file_upload_id: created.id,
                file: {
                    data: audio.data.slice(offset, Math.min(size, offset + partSize), audio.data.type),
                    filename: audio.filename,
                },
                part_number: String(part),
            });
        await client.fileUploads.complete({ file_upload_id: created.id });
    }
    else
        await client.fileUploads.send({ file_upload_id: created.id, file: audio });
    return created.id;
}
export async function runNotion(request, host) {
    const client = sdk(host);
    if (request.operation === "discover") {
        const resources = [];
        let cursor;
        const seen = new Set();
        do {
            const result = await client.search({
                filter: { property: "object", value: "data_source" },
                page_size: 100,
                ...(cursor ? { start_cursor: cursor } : {}),
            });
            for (const source of result.results) {
                if (source.object !== "data_source" ||
                    !("properties" in source) ||
                    !("title" in source))
                    continue;
                const name = source.title.map((t) => t.plain_text).join("") || "Sin título";
                const properties = Object.entries(source.properties).map(([name, p]) => ({ name, type: p.type }));
                const schema = {
                    id: source.id,
                    title: name,
                    databaseTitle: name,
                    properties,
                };
                const existing = z
                    .record(z.string(), z.string())
                    .safeParse(request.config?.columns);
                resources.push({
                    configuration: {
                        source: schema,
                        columns: suggestedColumns(schema, existing.success ? existing.data : {}),
                        body: "{{transcripcion}}",
                    },
                    id: source.id,
                    name,
                    schema: {
                        id: source.id,
                        title: name,
                        databaseTitle: name,
                        properties,
                    },
                });
            }
            cursor = result.has_more ? result.next_cursor || undefined : undefined;
            if (cursor) {
                if (seen.has(cursor))
                    throw Error("Notion repitió el cursor de paginación");
                seen.add(cursor);
            }
        } while (cursor);
        return { resources };
    }
    const config = notionConfig(request.config);
    let ref = request.previous?.locator
        ? { id: request.previous.locator, url: request.previous.url }
        : undefined;
    if (request.operation === "remove") {
        if (!ref)
            throw Error("Falta el localizador de la publicación");
        await client.pages.update({ page_id: ref.id, archived: true });
        const receipt = {
            version: 1,
            provider: "notion",
            locator: ref.id,
            ...(ref.url ? { url: ref.url } : {}),
            state: "removed",
        };
        await host.checkpoint(receipt);
        return { locator: ref.id, receipt };
    }
    const problem = notionProblem(config);
    if (problem)
        throw Error(problem);
    const note = request.note;
    if (!note)
        throw Error("Falta la nota");
    if (request.operation === "preview")
        return notionPayload(note, config, "ejemplo");
    const audio = config.body.includes("{{audio}}")
        ? await upload(client, host)
        : undefined;
    const payload = notionPayload(note, config, audio);
    if (!ref) {
        const keyColumn = config.source.properties.find((p) => p.type === "rich_text" &&
            sole(config.columns[p.name] || "") === "clave");
        if (keyColumn) {
            const found = await client.dataSources.query({
                data_source_id: config.source.id,
                filter: { property: keyColumn.name, rich_text: { equals: note.key } },
                page_size: 1,
            });
            const page = found.results[0];
            if (page && "url" in page)
                ref = { id: page.id, url: page.url };
        }
    }
    if (!ref && request.previous?.state === "creating")
        throw Error("El resultado de la creación anterior es incierto; reconcilia el localizador antes de publicar de nuevo");
    if (ref) {
        try {
            await client.pages.update({
                page_id: ref.id,
                properties: payload.properties,
            });
        }
        catch (error) {
            if (error &&
                typeof error === "object" &&
                "status" in error &&
                error.status === 404)
                ref = undefined;
            else
                throw error;
        }
    }
    let offset = 0;
    if (!ref) {
        const creating = {
            version: 1,
            provider: "notion",
            locator: "",
            key: note.key,
            state: "creating",
        };
        await host.checkpoint(creating);
        const created = await client.pages
            .create({
            parent: { type: "data_source_id", data_source_id: config.source.id },
            properties: payload.properties,
            children: payload.children.slice(0, 100),
        })
            .catch(async (error) => {
            if (error &&
                typeof error === "object" &&
                "status" in error &&
                typeof error.status === "number" &&
                error.status >= 400 &&
                error.status < 500 &&
                error.status !== 408)
                await host.checkpoint({ ...creating, state: "rejected" });
            throw error;
        });
        if (!created.id)
            throw Error("Notion no devolvió el ID de la página creada");
        ref = { id: created.id, url: "url" in created ? created.url : undefined };
        offset = 100;
    }
    const receipt = {
        version: 1,
        provider: "notion",
        locator: ref.id,
        ...(ref.url ? { url: ref.url } : {}),
        key: note.key,
        state: "applying",
    };
    await host.checkpoint(receipt);
    if (offset === 0) {
        const ids = [];
        let cursor;
        const seen = new Set();
        do {
            const list = await client.blocks.children.list({
                block_id: ref.id,
                page_size: 100,
                ...(cursor ? { start_cursor: cursor } : {}),
            });
            ids.push(...list.results.map((b) => b.id));
            cursor = list.has_more ? list.next_cursor || undefined : undefined;
            if (cursor) {
                if (seen.has(cursor))
                    throw Error("Notion repitió el cursor de paginación");
                seen.add(cursor);
            }
        } while (cursor);
        for (const id of ids)
            await client.blocks.delete({ block_id: id });
    }
    for (let i = offset; i < payload.children.length; i += 100)
        await client.blocks.children.append({
            block_id: ref.id,
            children: payload.children.slice(i, i + 100),
        });
    receipt.state = "published";
    await host.checkpoint(receipt);
    return { locator: ref.id, ...(ref.url ? { url: ref.url } : {}), receipt };
}
