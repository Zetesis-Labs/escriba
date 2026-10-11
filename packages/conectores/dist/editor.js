import { notionConfig, notionProblem, suggestedColumns } from "./notion.js";
import { standardDocuments } from "./okf.js";
import { runNotion } from "./notion.js";
const notionDefault = { source: { id: "", title: "", databaseTitle: "", properties: [] }, columns: {}, body: "{{transcripcion}}" };
export const notionDefaultConfiguration = notionDefault;
export const okfDefaultConfiguration = { folder: "", documents: standardDocuments() };
function record(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
}
function string(value, fallback = "") { return typeof value === "string" ? value : fallback; }
function source(value) {
    const raw = record(value);
    if (raw.properties !== undefined && !Array.isArray(raw.properties))
        throw Error("source.properties: se esperaba una lista");
    return { id: string(raw.id), title: string(raw.title), databaseTitle: string(raw.databaseTitle), properties: Array.isArray(raw.properties) ? raw.properties.map((item, index) => {
            const property = record(item);
            if (typeof property.name !== "string" || typeof property.type !== "string")
                throw Error(`source.properties.${index}: propiedad no válida`);
            return { name: property.name, type: property.type };
        }) : [] };
}
function notionConfiguration(raw) {
    const input = record(raw);
    const columns = record(input.columns);
    const normalized = { source: source(input.source), columns: Object.fromEntries(Object.entries(columns).filter((entry) => typeof entry[1] === "string")), body: string(input.body, "{{transcripcion}}") };
    return normalized.source.id ? notionConfig(normalized) : normalized;
}
function okfConfiguration(raw) {
    const input = record(raw);
    if (input.documents !== undefined && !Array.isArray(input.documents))
        throw Error("documents: se esperaba una lista");
    const documents = Array.isArray(input.documents) ? input.documents.map((item, index) => {
        const doc = record(item);
        if (typeof doc.id !== "string")
            throw Error(`documents.${index}.id: identificador no válido`);
        if (!Array.isArray(doc.properties))
            throw Error(`documents.${index}.properties: se esperaba una lista`);
        return { id: doc.id, name: string(doc.name), path: string(doc.path), body: string(doc.body), properties: doc.properties.map((item, propertyIndex) => {
                const property = record(item);
                if (typeof property.key !== "string" || typeof property.value !== "string")
                    throw Error(`documents.${index}.properties.${propertyIndex}: propiedad no válida`);
                return { ...(typeof property.id === "string" ? { id: property.id } : {}), key: property.key, value: property.value };
            }) };
    }) : standardDocuments();
    return { folder: string(input.folder), documents, ...(typeof input.producer === "string" ? { producer: input.producer } : {}) };
}
function writable(source) {
    const properties = source.properties.filter((property) => ["title", "rich_text", "multi_select", "select", "date", "number", "url"].includes(property.type));
    return [...properties.filter((property) => property.type === "title"), ...properties.filter((property) => property.type !== "title")];
}
function richText(value) { return Array.isArray(value) ? value.map((run) => string(record(record(run).text).content)).join("") : ""; }
function displayedProperty(value) {
    const [type, content] = Object.entries(record(value))[0] ?? [];
    if (type === "title" || type === "rich_text")
        return richText(content) || "—";
    if (type === "multi_select" && Array.isArray(content))
        return content.map((item) => string(record(item).name)).filter(Boolean).join(", ") || "—";
    if (type === "select")
        return string(record(content).name, "—");
    if (type === "date")
        return string(record(content).start, "—");
    if (type === "number" && typeof content === "number")
        return String(content);
    if (type === "url" && typeof content === "string")
        return content;
    return "—";
}
function displayedBlock(value) {
    const block = record(value);
    const type = string(block.type, "paragraph");
    if (type === "audio")
        return "▶︎ Audio";
    const text = richText(record(block[type]).rich_text);
    if (type === "bulleted_list_item")
        return `• ${text}`;
    const level = /^heading_([123])$/.exec(type)?.[1];
    return level ? `${"#".repeat(Number(level))} ${text}` : text;
}
async function notionView(raw, state, preview) {
    const config = notionConfiguration(raw);
    const stateSources = Array.isArray(state.sources) ? state.sources.map(source).filter((entry) => entry.id) : [];
    const sources = Array.isArray(state.sources) ? stateSources : config.source.id ? [config.source] : [];
    const selected = config.source.id ? config.source : null;
    const sections = [{ title: "Bases y columnas", fields: [{ type: "action", id: "refresh-sources", label: "Actualizar bases y columnas" }] }];
    if (sources.length)
        sections.push({ title: "Base de datos", fields: [{ type: "select", path: ["source", "id"], label: "Guardar en", action: "select-source", options: [{ label: "Sin elegir", value: "" }, ...sources.map((item) => ({ label: item.databaseTitle === item.title || !item.title ? item.databaseTitle : `${item.databaseTitle} › ${item.title}`, value: item.id }))] }] });
    if (selected) {
        const labels = { title: "título", rich_text: "texto", multi_select: "selección múltiple", select: "selección", date: "fecha", number: "número", url: "URL" };
        sections.push({ title: "Propiedades", help: "Una fila por columna de tu base: escribe qué va en ella, con texto y datos. Vacía, Escriba no la toca. Las columnas de casilla, persona, archivo o relación no aparecen porque Escriba no escribe en ellas.", fields: writable(selected).map((column) => ({ type: "template", path: ["columns", column.name], label: `${column.name} · ${labels[column.type]}`, context: "property", placeholder: "No se exporta" })) });
        sections.push({ title: "Cuerpo de la página", help: "Escribe como en una página: # para títulos, - para viñetas, **negrita**. Pulsa / para insertar un dato; el dato Audio sube el fichero a Notion. Una línea cuyos datos salen vacíos no se escribe.", fields: [{ type: "template", path: ["body"], label: "Cuerpo", context: "body", placeholder: "Escribe aquí. Pulsa / para insertar un dato.", multiline: true }] });
    }
    const view = { sections, subtitle: selected ? selected.databaseTitle === selected.title || !selected.title ? selected.databaseTitle : `${selected.databaseTitle} › ${selected.title}` : "Sin base elegida" };
    if (selected) {
        try {
            const result = await preview("notion", config);
            const properties = record(result.properties);
            view.previews = [{ title: "Así queda", properties: writable(selected).filter((item) => Object.hasOwn(properties, item.name)).map((item) => ({ label: item.name, value: displayedProperty(properties[item.name]) })), text: Array.isArray(result.children) ? result.children.map(displayedBlock).join("\n\n") : "" }];
        }
        catch (error) {
            view.problem = error instanceof Error ? error.message : String(error);
        }
    }
    return view;
}
function selectedDocument(config, state) {
    const chosen = typeof state.selectedDocument === "string" ? state.selectedDocument : config.documents[0]?.id;
    return config.documents.find((doc) => doc.id === chosen) ?? config.documents[0];
}
async function okfView(raw, state, preview) {
    const config = okfConfiguration(raw);
    const selected = selectedDocument(config, state);
    const sections = [
        { title: "Carpeta del bundle", help: "Escriba gestiona esta carpeta como un bundle OKF: escribe los documentos, un index.md en cada carpeta y log.md. Si va dentro de un bundle más grande, elige una subcarpeta propia.", fields: [{ type: "folder", path: ["folder"], label: "Carpeta" }] },
        { title: "Documentos", help: "Cada grabación escribe un fichero por documento. Para enlazarlos entre sí, inserta el dato «Enlace a…».", fields: [{ type: "select", row: "documents", path: [], value: selected?.id ?? "", label: "Documento", action: "select-document", options: config.documents.map((doc) => ({ value: doc.id, label: doc.name || "Sin nombre" })) }, { type: "action", row: "documents", id: "add-document", label: "+" }, { type: "action", row: "documents", id: "remove-document", label: "−", disabled: !selected, destructive: true }] },
    ];
    const view = { sections, subtitle: config.folder || "Sin carpeta elegida" };
    if (selected) {
        const index = config.documents.findIndex((doc) => doc.id === selected.id);
        const base = ["documents", index];
        const links = config.documents.map((doc) => ({ id: doc.id, name: doc.name }));
        sections.push({ title: "Documento", help: "La ruta dentro del bundle. Escribe // para insertar un dato en ella; el título se pone sin tildes ni signos.", fields: [{ type: "text", path: [...base, "name"], label: "Nombre" }, { type: "template", path: [...base, "path"], label: "Ruta", context: "path", placeholder: "carpeta/[Día]-[Título].md" }] });
        sections.push({ title: "Propiedades", help: "Son el frontmatter del fichero: clave y valor, con texto y datos mezclados. type es obligatorio en OKF. Escriba añade siempre escriba_key y generated para reconocer sus ficheros.", fields: [...selected.properties.flatMap((property, propertyIndex) => {
                    const fixed = property.key.trim() === "type" && selected.properties.findIndex((item) => item.key.trim() === "type") === propertyIndex;
                    const row = `property:${selected.id}:${property.id ?? propertyIndex}`;
                    return [
                        { type: "text", row, path: [...base, "properties", propertyIndex, "key"], label: "Clave", placeholder: "clave", disabled: fixed },
                        { type: "template", row, path: [...base, "properties", propertyIndex, "value"], label: property.key || "Valor", context: "property", links, current: selected.id, placeholder: "valor" },
                        ...fixed ? [] : [{ type: "action", row, id: `remove-property:${encodeURIComponent(selected.id)}:${propertyIndex}`, label: `Quitar propiedad ${property.key}`, destructive: true }],
                    ];
                }), { type: "action", id: "add-property", label: "Añadir propiedad" }] });
        sections.push({ title: "Cuerpo", help: "Escribe como en una página: Markdown, con # para los títulos. Pulsa / donde quieras para insertar un dato, o usa +. Una línea cuyos datos salen vacíos no se escribe.", fields: [{ type: "template", path: [...base, "body"], label: "Cuerpo", context: "body", links, current: selected.id, placeholder: "Escribe aquí. Pulsa / para insertar un dato.", multiline: true }] });
        try {
            const previewResult = await preview("okf", { ...config, folder: config.folder || "/" });
            const file = Array.isArray(previewResult.files) ? previewResult.files.map(record).find((item) => item.documentID === selected.id) : undefined;
            if (file)
                view.previews = [{ title: "Así queda", text: `▤ ${string(file.path)}\n\n${string(file.contents)}` }];
        }
        catch (error) {
            view.problem = error instanceof Error ? error.message : String(error);
        }
    }
    return view;
}
export async function describeBuiltin(provider, config, state, preview) {
    return { view: provider === "notion" ? await notionView(config, state, preview) : await okfView(config, state, preview) };
}
export async function actionBuiltin(provider, config, state, action, value, preview, host) {
    if (provider === "notion") {
        const current = notionConfiguration(config);
        if (action === "refresh-sources") {
            if (!host)
                throw Error("Falta el host de capacidades");
            const discovered = await runNotion({ operation: "discover", provider: "notion", config: current }, host);
            const sources = Array.isArray(discovered.resources) ? discovered.resources.map((item) => source(record(item).schema)).filter((item) => item.id) : [];
            const fresh = sources.find((item) => item.id === current.source.id);
            const configuration = fresh ? { source: fresh, columns: suggestedColumns(fresh, current.columns), body: current.body } : current;
            const nextState = { ...state, sources };
            const result = await describeBuiltin(provider, configuration, nextState, preview);
            return { configuration, state: nextState, ...result, ...(sources.length ? {} : { problem: "La integración no tiene acceso a ninguna base. Compártele una desde Notion." }) };
        }
        if (action === "select-source") {
            const sources = Array.isArray(state.sources) ? state.sources.map(source) : [];
            const chosen = sources.find((item) => item.id === value);
            if (!chosen && value !== "")
                throw Error("Base de Notion desconocida");
            const configuration = chosen ? { source: chosen, columns: suggestedColumns(chosen, current.source.id === chosen.id ? current.columns : {}), body: current.body } : { source: notionDefault.source, columns: {}, body: current.body };
            return { configuration, state, ...await describeBuiltin(provider, configuration, state, preview) };
        }
        throw Error(`Acción de Notion desconocida: ${action}`);
    }
    const current = okfConfiguration(config);
    let nextState = state;
    let documents = [...current.documents];
    const selected = selectedDocument(current, state);
    if (action === "select-document") {
        if (!documents.some((doc) => doc.id === value))
            throw Error("Documento desconocido");
        nextState = { ...state, selectedDocument: String(value) };
    }
    else if (action === "add-document") {
        const id = crypto.randomUUID();
        documents.push({ id, name: `Documento ${documents.length + 1}`, path: "documentos/{{dia}}-{{titulo}}.md", properties: [{ key: "type", value: "Documento" }, { key: "title", value: "{{titulo}}" }], body: "{{resumen}}" });
        nextState = { ...state, selectedDocument: id };
    }
    else if (action === "remove-document") {
        if (!selected)
            throw Error("Falta un documento seleccionado");
        documents = documents.filter((doc) => doc.id !== selected.id);
        nextState = { ...state, selectedDocument: documents[0]?.id ?? "" };
    }
    else if (action === "add-property") {
        if (!selected)
            throw Error("Falta un documento seleccionado");
        documents = documents.map((doc) => doc.id === selected.id ? { ...doc, properties: [...doc.properties, { id: crypto.randomUUID(), key: "", value: "" }] } : doc);
    }
    else if (action.startsWith("remove-property:")) {
        const match = /^remove-property:([^:]+):(\d+)$/.exec(action);
        if (!match)
            throw Error("Acción de propiedad no válida");
        const id = decodeURIComponent(match[1]);
        const index = Number(match[2]);
        const doc = documents.find((item) => item.id === id);
        if (!doc || !doc.properties[index])
            throw Error("Propiedad desconocida");
        const firstType = doc.properties.findIndex((item) => item.key.trim() === "type");
        if (index === firstType)
            throw Error("La propiedad type es obligatoria");
        documents = documents.map((item) => item.id === id ? { ...item, properties: item.properties.filter((_, candidate) => candidate !== index) } : item);
    }
    else
        throw Error(`Acción de OKF desconocida: ${action}`);
    const configuration = { ...current, documents };
    return { configuration, state: nextState, ...await describeBuiltin(provider, configuration, nextState, preview) };
}
export function builtinProblem(provider, config) {
    if (provider === "notion") {
        const parsed = notionConfiguration(config);
        if (!parsed.source.id)
            return "Elige la base donde guardar.";
        return notionProblem(parsed);
    }
    const parsed = okfConfiguration(config);
    if (!parsed.folder.trim())
        return "Elige la carpeta donde guardar las notas.";
    if (!parsed.documents.length)
        return "Añade al menos un documento.";
    for (const document of parsed.documents)
        if (!document.properties.find((property) => property.key.trim() === "type")?.value.trim())
            return `«${document.name}» necesita un valor en type: OKF lo exige.`;
    for (let index = 0; index < parsed.documents.length; index++)
        for (let other = index + 1; other < parsed.documents.length; other++)
            if (parsed.documents[index].path.trim().replace(/^\/+|\/+$/g, "") === parsed.documents[other].path.trim().replace(/^\/+|\/+$/g, ""))
                return `«${parsed.documents[index].name}» y «${parsed.documents[other].name}» escriben en la misma ruta.`;
}
