import type { JSONValue } from "../types";

export type DataRowValue = { kind: "text"; text: string } | { kind: "list"; items: string[] } | { kind: "group" };
export interface DataRow {
  label: string;
  depth: number;
  value: DataRowValue;
}

const emptyValue = "—";
type Node = Record<string, JSONValue> | undefined;

const isObject = (value: JSONValue | undefined): value is Record<string, JSONValue> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function solid(node: JSONValue | undefined): Node {
  if (!isObject(node)) return undefined;
  const branches = node.anyOf;
  if (Array.isArray(branches)) return branches.find((branch) => isObject(branch) && branch.type !== "null") as Node;
  return node;
}

function titleOf(node: JSONValue | undefined) {
  if (isObject(node) && typeof node.title === "string") return node.title;
  const inner = solid(node);
  return typeof inner?.title === "string" ? inner.title : undefined;
}

function scalarText(value: JSONValue): string | null {
  if (value === null) return emptyValue;
  if (typeof value === "boolean") return value ? "sí" : "no";
  if (typeof value === "number") return String(value).replace(".", ",");
  if (typeof value === "string") return value;
  return null;
}

function field(name: string, value: JSONValue, schema: JSONValue | undefined, depth: number): DataRow[] {
  const properties = solid(schema)?.properties;
  const node = isObject(properties) ? properties[name] : undefined;
  return rows(titleOf(node) ?? name, value, node, depth);
}

function rows(label: string, value: JSONValue, schema: JSONValue | undefined, depth: number): DataRow[] {
  if (value === null) return [];
  if (isObject(value)) {
    const children = Object.entries(value).flatMap(([name, child]) => field(name, child, schema, depth + 1));
    return children.length ? [{ label, depth, value: { kind: "group" } }, ...children] : [];
  }
  if (Array.isArray(value)) {
    const scalars = value.map(scalarText);
    if (scalars.every((item) => item !== null))
      return scalars.length ? [{ label, depth, value: { kind: "list", items: scalars as string[] } }] : [];
    const itemSchema = solid(schema)?.items;
    return value.flatMap((item, index) => rows(`${label} ${index + 1}`, item, itemSchema, depth));
  }
  return [{ label, depth, value: { kind: "text", text: scalarText(value) ?? emptyValue } }];
}

export function dataRows(value: JSONValue | undefined, schema?: JSONValue): DataRow[] {
  if (!isObject(value)) return [];
  return Object.entries(value).flatMap(([name, child]) => field(name, child, schema, 0));
}
