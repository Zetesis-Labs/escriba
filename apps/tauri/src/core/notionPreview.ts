import type { Result } from "@escriba/conectores";
import { writableColumns } from "./connectors";

function fields(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function richText(value: unknown) {
  return Array.isArray(value) ? value.map((run) => fields(fields(run).text).content).filter((text) => typeof text === "string").join("") : "";
}

function displayedProperty(value: unknown) {
  const [type, content] = Object.entries(fields(value))[0] ?? [];
  let text = "";
  if (type === "title" || type === "rich_text") text = richText(content);
  if (type === "multi_select" && Array.isArray(content)) text = content.map((option) => fields(option).name).filter((name) => typeof name === "string").join(", ");
  if (type === "select" && typeof fields(content).name === "string") text = String(fields(content).name);
  if (type === "date" && typeof fields(content).start === "string") text = String(fields(content).start);
  if (type === "number" && typeof content === "number") text = String(content);
  if (type === "url" && typeof content === "string") text = content;
  return text || "—";
}

function displayedBlock(value: unknown) {
  const block = fields(value);
  const type = typeof block.type === "string" ? block.type : "paragraph";
  if (type === "audio") return "▶︎ Audio";
  const text = richText(fields(block[type]).rich_text);
  if (type === "bulleted_list_item") return `• ${text}`;
  const level = /^heading_([123])$/.exec(type)?.[1];
  return level ? `${"#".repeat(Number(level))} ${text}` : text;
}

export function notionPreview(result: Result, source: { properties: { name: string; type: string }[] }) {
  const properties = fields(result.properties);
  const ordered = writableColumns(source).filter((property) => Object.hasOwn(properties, property.name));
  return {
    properties: ordered.map((property) => ({ name: property.name, value: displayedProperty(properties[property.name]) })),
    text: Array.isArray(result.children) ? result.children.map(displayedBlock).join("\n\n") : "",
  };
}
