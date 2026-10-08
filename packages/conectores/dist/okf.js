import { z } from "zod";
import { sha256 } from "@noble/hashes/sha256";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils";
import { values, render, sole, slug, quote, transcript, cleanBody, linkText, dateValues, monthHeading, } from "./templates.js";
const property = z.object({
    id: z.string().optional(),
    key: z.string(),
    value: z.string(),
});
const document = z.object({
    id: z.string(),
    name: z.string(),
    path: z.string(),
    properties: z.array(property),
    body: z.string(),
});
export const okfSchema = z.object({
    folder: z.string().min(1),
    documents: z.array(document).min(1).optional(),
    producer: z.string().optional(),
});
export function standardDocuments() {
    const recording = [
        ["recorded_at", "{{fecha-iso}}"],
        ["duration", "{{segundos}}"],
        ["speakers", "{{hablantes}}"],
    ];
    const props = (pairs) => pairs.map(([key, value]) => ({ key, value }));
    return [
        {
            id: "nota",
            name: "Nota",
            path: "notas/{{dia}}-{{titulo}}.md",
            properties: props([
                ["type", "Nota de voz"],
                ["title", "{{titulo}}"],
                ["description", "{{descripcion}}"],
                ["tags", "{{etiquetas}}"],
                ...recording,
            ]),
            body: "# Resumen\n\n{{resumen}}\n\n# Transcripción\n\n{{enlace:transcripcion}}",
        },
        {
            id: "transcripcion",
            name: "Transcripción",
            path: "transcripciones/{{dia}}-{{titulo}}.md",
            properties: props([
                ["type", "Transcripción"],
                ["title", "Transcripción: {{titulo}}"],
                ["description", "Transcripción completa de «{{titulo}}»."],
                ...recording,
            ]),
            body: "De la nota {{enlace:nota}}.\n\n{{transcripcion}}",
        },
    ];
}
export function okfConfig(config) {
    const parsed = okfSchema.parse(config);
    return { ...parsed, documents: parsed.documents || standardDocuments() };
}
const hash = (text) => bytesToHex(sha256(utf8ToBytes(text)));
const reserved = (path) => ["index.md", "log.md"].includes(path.split("/").at(-1));
const safe = (path) => !!path &&
    !path.startsWith("/") &&
    !path.includes("\\") &&
    !path.includes("\0") &&
    !path.split("/").some((x) => x === ".." || x === "." || !x);
function fields(contents) {
    if (!contents.startsWith("---\n"))
        return {};
    return Object.fromEntries(contents
        .split("\n")
        .slice(1)
        .slice(0, contents.split("\n").slice(1).indexOf("---"))
        .flatMap((line) => {
        const m = line.match(/^([^:]+):\s*(.*)$/);
        if (!m)
            return [];
        let value = m[2];
        if (value.startsWith('"')) {
            try {
                value = JSON.parse(value);
            }
            catch {
                return [];
            }
        }
        else if (value.startsWith("'"))
            value = value.slice(1, -1).replace(/''/g, "'");
        return [[m[1].trim(), value]];
    }));
}
function pathFor(template, note) {
    if (template.includes("\\") || template.includes("\0"))
        throw Error("Ruta OKF no válida");
    const v = values(note);
    const raw = render(template, (t) => t === "dia" ? v.date.day : slug(v.inline(t)));
    const result = raw
        .split("/")
        .map((x) => x.trim())
        .filter((x) => x && x !== "." && x !== "..")
        .join("/") || "nota.md";
    const path = result.toLowerCase().endsWith(".md") ? result : result + ".md";
    if (!safe(path) || reserved(path))
        throw Error(`Ruta reservada o no válida: ${path}`);
    return path;
}
function content(doc, note, links, producer, now) {
    const v = values(note);
    const inline = (text) => render(text, (t) => t.startsWith("enlace:")
        ? links[t.slice(7)]
            ? "/" + links[t.slice(7)].path
            : ""
        : v.inline(t));
    const type = inline(doc.properties.find((p) => p.key.trim() === "type")?.value || "Documento").trim() || "Documento";
    const plain = !/^[-?:,\[\]{}#&*!|>'"%@`]/.test(type) && !/: | #|\n/.test(type);
    const lines = [`type: ${plain ? type : quote(type)}`];
    for (const p of doc.properties) {
        const key = p.key.trim();
        if (!key || ["type", "generated", "escriba_key"].includes(key))
            continue;
        const token = sole(p.value);
        let value = inline(p.value).trim();
        if (token === "etiquetas") {
            const tags = [
                ...new Set(v.tags
                    .map((t) => t
                    .normalize("NFD")
                    .replace(/[\u0300-\u036f]/g, "")
                    .toLowerCase()
                    .match(/[a-z0-9]+/g)
                    ?.join("-") || "")
                    .filter(Boolean)),
            ];
            value = tags.length ? "[" + tags.join(", ") + "]" : "";
        }
        else if (token === "hablantes")
            value = v.speakers.length
                ? "[" + v.speakers.map(quote).join(", ") + "]"
                : "";
        else if (token !== "segundos" && token !== "fecha-iso")
            value = value ? quote(value) : "";
        if (value)
            lines.push(`${/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(key) ? key : quote(key)}: ${value}`);
    }
    lines.push(`escriba_key: ${quote(note.key)}`, `generated: { by: ${quote(producer)}, at: ${dateValues(now, "UTC").iso} }`);
    const body = cleanBody(render(doc.body, (t) => {
        if (t.startsWith("transcripcion"))
            return transcript(note, t, true);
        if (t === "audio")
            return `[Audio](${note.source})`;
        if (t.startsWith("enlace:")) {
            const l = links[t.slice(7)];
            return l ? `[${linkText(l.title)}](/${l.path})` : "";
        }
        return v.inline(t);
    }));
    return ("---\n" + lines.join("\n") + "\n---\n" + (body ? "\n" + body + "\n" : ""));
}
function directoryIndex(files, paths) {
    const groups = new Map();
    for (const path of paths) {
        const name = path.split("/").at(-1);
        const match = name.match(/^(\d{4}-(?:0[1-9]|1[0-2]))-/);
        const key = match?.[1] || "Otras";
        groups.set(key, [...(groups.get(key) || []), path]);
    }
    return ([...groups.keys()]
        .sort((a, b) => a === "Otras" ? 1 : b === "Otras" ? -1 : b.localeCompare(a))
        .map((key) => "# " +
        (key === "Otras" ? key : monthHeading(key)) +
        "\n\n" +
        groups
            .get(key)
            .sort((a, b) => key === "Otras" ? a.localeCompare(b) : b.localeCompare(a))
            .map((path) => {
            const f = fields(files[path]);
            const name = path.split("/").at(-1);
            return `* [${linkText(f.title || name.slice(0, -3))}](${name})${f.description ? " - " + f.description : ""}`;
        })
            .join("\n"))
        .join("\n\n") + "\n");
}
function indexes(files, docs) {
    const concepts = Object.keys(files).filter((p) => p.endsWith(".md") && !reserved(p));
    const owned = concepts.filter((p) => fields(files[p]).escriba_key);
    const dirs = [
        ...new Set(owned.map((p) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : ""))),
    ].sort();
    const result = {};
    for (const dir of dirs.filter(Boolean))
        result[dir + "/index.md"] = directoryIndex(files, concepts.filter((p) => p.slice(0, p.lastIndexOf("/")) === dir));
    if (dirs.length) {
        let root = "# Notas de voz\n";
        const folders = dirs.filter(Boolean).map((dir) => {
            const names = docs
                .filter((d) => d.path.slice(0, d.path.lastIndexOf("/")) === dir)
                .map((d) => d.name);
            return `* [${dir}](${dir}/)${names.length ? " - " + names.join(", ") : ""}`;
        });
        if (folders.length)
            root += "\n" + folders.join("\n") + "\n";
        if (dirs.includes(""))
            root +=
                "\n" +
                    directoryIndex(files, concepts.filter((p) => !p.includes("/")));
        result["index.md"] = root;
    }
    return result;
}
function log(existing, line, marker, day) {
    const current = existing || "# Registro\n";
    const at = current.indexOf("\n## ");
    const header = (at < 0 ? current : current.slice(0, at)).trimEnd();
    const rest = at < 0 ? "" : current.slice(at + 1);
    if (rest.startsWith("## " + day + "\n")) {
        const end = rest.indexOf("\n## ", 1);
        const section = end < 0 ? rest : rest.slice(0, end);
        if (section.includes(marker))
            return current;
        return (header +
            "\n\n## " +
            day +
            "\n\n" +
            line +
            "\n" +
            rest.slice(("## " + day).length).trimStart());
    }
    return (header + "\n\n## " + day + "\n\n" + line + "\n" + (rest ? "\n" + rest : ""));
}
export async function runOKF(request, host) {
    const config = okfConfig(request.config);
    const previous = request.previous;
    if ([
        ...Object.keys(previous?.files || {}),
        ...Object.keys(previous?.pending || {}),
        ...(previous?.locator ? [previous.locator] : []),
    ].some((path) => !safe(path)))
        throw Error("El recibo contiene una ruta no válida");
    const now = request.now || new Date().toISOString();
    const snapshot = await host.files.snapshot();
    if (Object.keys(snapshot).some((p) => !safe(p)))
        throw Error("La carpeta contiene una ruta no válida");
    if (previous?.folder && previous.folder !== config.folder)
        throw Error("La carpeta ha cambiado; se requiere una decisión de traslado");
    let key = previous?.key || request.note?.key;
    const locator = previous?.locator;
    if (!key && locator && snapshot[locator])
        key = fields(snapshot[locator]).escriba_key;
    const owned = {};
    if (previous?.files) {
        Object.assign(owned, previous.files);
        for (const [path, fingerprint] of Object.entries(previous.pending || {})) {
            if (snapshot[path] !== undefined && hash(snapshot[path]) === fingerprint)
                owned[path] = fingerprint;
        }
    }
    else if (key) {
        for (const [path, text] of Object.entries(snapshot))
            if (!reserved(path) && fields(text).escriba_key === key)
                owned[path] = hash(text);
    }
    if (request.operation === "migrate") {
        const receipt = {
            version: 1,
            provider: "okf",
            locator: locator || Object.keys(owned)[0] || "",
            key,
            folder: config.folder,
            files: owned,
        };
        return { config, receipt };
    }
    for (const [path, fingerprint] of Object.entries(owned)) {
        if (snapshot[path] !== undefined &&
            hash(snapshot[path]) !== fingerprint &&
            !reserved(path))
            throw Error(`El fichero ${path} cambió fuera de Escriba`);
    }
    const after = { ...snapshot };
    const paths = [];
    const changes = [];
    const docs = config.documents;
    const note = request.note;
    if (request.operation !== "remove") {
        if (!note)
            throw Error("Falta la nota");
        for (const doc of docs) {
            const base = pathFor(doc.path, note);
            let path = base;
            let count = 1;
            while (paths.includes(path) ||
                (after[path] !== undefined && !(path in owned)))
                path = base.slice(0, -3) + "-" + ++count + ".md";
            paths.push(path);
        }
        const links = Object.fromEntries(docs.map((doc, i) => [
            doc.id,
            {
                path: paths[i],
                title: render(doc.properties.find((p) => p.key.trim() === "title")?.value ||
                    "{{titulo}}", values(note).inline),
            },
        ]));
        docs.forEach((doc, i) => {
            after[paths[i]] = content(doc, note, links, config.producer || "escriba", now);
        });
    }
    for (const path of Object.keys(owned)) {
        if (!reserved(path) && !paths.includes(path))
            delete after[path];
    }
    const oldIndexes = indexes(snapshot, docs);
    const newIndexes = indexes(after, docs);
    for (const path of new Set([
        ...Object.keys(oldIndexes),
        ...Object.keys(newIndexes),
    ])) {
        const existing = snapshot[path];
        if (existing !== undefined &&
            owned[path] !== hash(existing) &&
            existing !== oldIndexes[path])
            throw Error(`El índice ${path} no pertenece a Escriba`);
        if (newIndexes[path])
            after[path] = newIndexes[path];
        else
            delete after[path];
    }
    const main = paths[0] || locator;
    if (main) {
        const title = note
            ? values(note).title
            : fields(snapshot[main] || "").title || main;
        const removing = request.operation === "remove";
        const marker = removing ? `(${main})` : `(/${main})`;
        after["log.md"] = log(snapshot["log.md"], removing
            ? `* **Baja**: ${title} (${main})`
            : `* **${Object.keys(owned).length ? "Actualización" : "Alta"}**: [${linkText(title)}](/${main})`, marker, dateValues(now, note?.timeZone || "UTC").day);
    }
    for (const path of new Set([
        ...Object.keys(snapshot),
        ...Object.keys(after),
    ])) {
        if (snapshot[path] !== after[path])
            changes.push({
                path,
                contents: after[path] ?? null,
                expectedContents: snapshot[path] ?? null,
            });
    }
    const files = Object.fromEntries([...paths, ...Object.keys(newIndexes), "log.md"]
        .filter((p) => after[p] !== undefined)
        .map((p) => [p, hash(after[p])]));
    const receipt = {
        version: 1,
        provider: "okf",
        locator: main || "",
        key,
        folder: config.folder,
        files,
        state: request.operation === "remove" ? "removed" : "published",
    };
    if (request.operation === "preview")
        return {
            files: paths.map((path, i) => ({
                documentID: docs[i].id,
                path,
                contents: after[path],
            })),
            changes,
            receipt,
        };
    await host.checkpoint({
        ...receipt,
        files: owned,
        pending: files,
        state: "applying",
    });
    await host.files.apply(changes);
    await host.checkpoint(receipt);
    return { locator: receipt.locator, receipt };
}
