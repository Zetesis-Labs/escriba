import type { JSONValue } from "../types";

export const recipeFormExport = "buildRecipeForm";
export const maximumTextLines = 20;
export const maximumNumberChoices = 21;

type JSONObject = { [key: string]: JSONValue };

export interface FormOption {
  value: string;
  label: string;
}

export type FieldKind =
  | { type: "toggle" }
  | { type: "text"; lines: number }
  | { type: "number"; minimum: number | null; maximum: number | null; integer: boolean }
  | { type: "choice"; options: FormOption[] }
  | { type: "choices"; options: FormOption[] }
  | { type: "group"; fields: FormField[] };

export interface FormField {
  name: string;
  label: string;
  help: string | null;
  kind: FieldKind;
  nullable: boolean;
  required: boolean;
  defaultValue: JSONValue | undefined;
  dependsOn: string | null;
}

export interface RecipeForm {
  fields: FormField[];
}

export class RecipeFormProblem extends Error {
  constructor(
    readonly reason: "notAnObject" | "unsupported",
    readonly path = "",
    readonly what = "",
  ) {
    super(reason === "notAnObject" ? `${recipeFormExport} tiene que devolver un objeto: z.object({ … })` : `el formulario no sabe pintar ${what} en «${path}»`);
  }
}

export type RecipeFormLoad = { kind: "noForm" } | { kind: "form"; form: RecipeForm } | { kind: "problem"; problem: string };

const isObject = (value: JSONValue | undefined): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);
const textOf = (value: JSONValue | undefined) => (typeof value === "string" ? value : undefined);

function typeNames(value: JSONValue | undefined): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.filter((item): item is string => typeof item === "string");
  return [];
}

export function recipeFormLoad(schema: JSONValue | string | null | undefined): RecipeFormLoad {
  if (schema === null || schema === undefined) return { kind: "noForm" };
  try {
    const value = typeof schema === "string" ? (JSON.parse(schema) as JSONValue) : schema;
    return { kind: "form", form: recipeForm(value) };
  } catch (failure) {
    return { kind: "problem", problem: failure instanceof Error ? failure.message : String(failure) };
  }
}

export function recipeForm(schema: JSONValue): RecipeForm {
  if (!isObject(schema) || schema.anyOf !== undefined || JSON.stringify(typeNames(schema.type)) !== JSON.stringify(["object"]))
    throw new RecipeFormProblem("notAnObject");
  return { fields: fieldsOf(schema, []) };
}

const properties = (schema: JSONObject) => (isObject(schema.properties) ? Object.entries(schema.properties) : []);

function fieldsOf(schema: JSONObject, path: string[]): FormField[] {
  if (isObject(schema.additionalProperties) && properties(schema).length === 0)
    throw new RecipeFormProblem("unsupported", path.join("."), "un registro de claves libres (z.record)");
  const required = new Set((Array.isArray(schema.required) ? schema.required : []).filter((item): item is string => typeof item === "string"));
  const fields = properties(schema).map(([name, node]) => field(name, node, required.has(name), [...path, name]));
  for (const candidate of fields) {
    if (!candidate.dependsOn) continue;
    if (!fields.some((other) => other.name === candidate.dependsOn && other.kind.type === "toggle"))
      throw new RecipeFormProblem("unsupported", [...path, candidate.name].join("."), "un «si» que no es un interruptor de su mismo grupo");
  }
  return fields;
}

function textLines(value: JSONValue | undefined) {
  if (typeof value !== "number" || value < 1) return 1;
  return Math.floor(Math.min(value, maximumTextLines));
}

function unwrapNull(node: JSONObject): [JSONObject, boolean] {
  if (Array.isArray(node.anyOf)) {
    const branches = node.anyOf;
    const solid = branches.filter((branch) => !(isObject(branch) && JSON.stringify(typeNames(branch.type)) === JSON.stringify(["null"])));
    if (solid.length === 1 && solid.length < branches.length && isObject(solid[0])) return [solid[0], true];
    return [node, solid.length < branches.length];
  }
  const enumNull = Array.isArray(node.enum) && node.enum.includes(null);
  return [node, typeNames(node.type).includes("null") || enumNull];
}

function field(name: string, raw: JSONValue, required: boolean, path: string[]): FormField {
  const node = isObject(raw) ? raw : {};
  const [solid, nullable] = unwrapNull(node);
  let kind = kindOf(solid, path);
  if (kind.type === "text") kind = { type: "text", lines: textLines(node.lineas ?? solid.lineas) };
  return {
    name,
    label: textOf(node.title) ?? textOf(solid.title) ?? name,
    help: textOf(node.description) ?? textOf(solid.description) ?? null,
    kind,
    nullable,
    required,
    defaultValue: node.default !== undefined ? node.default : solid.default,
    dependsOn: textOf(node.si) ?? textOf(solid.si) ?? null,
  };
}

function kindOf(node: JSONObject, path: string[]): FieldKind {
  const place = path.join(".");
  if (node.$ref !== undefined) throw new RecipeFormProblem("unsupported", place, "un esquema recursivo ($ref)");
  const choice = optionsOf(node);
  if (choice) return { type: "choice", options: choice };
  if (node.anyOf !== undefined || node.oneOf !== undefined || node.allOf !== undefined)
    throw new RecipeFormProblem("unsupported", place, "una unión de tipos distintos");
  const types = typeNames(node.type).filter((type) => type !== "null");
  if (types.length !== 1) throw new RecipeFormProblem("unsupported", place, types.length === 0 ? "un valor sin tipo" : "una unión de tipos distintos");
  switch (types[0]) {
    case "boolean":
      return { type: "toggle" };
    case "string":
      return { type: "text", lines: 1 };
    case "number":
    case "integer":
      return {
        type: "number",
        minimum: typeof node.minimum === "number" ? node.minimum : null,
        maximum: typeof node.maximum === "number" ? node.maximum : null,
        integer: types[0] === "integer",
      };
    case "array": {
      if (node.prefixItems !== undefined) throw new RecipeFormProblem("unsupported", place, "una tupla (z.tuple)");
      const items = isObject(node.items) ? optionsOf(node.items) : null;
      if (!items) throw new RecipeFormProblem("unsupported", place, "una lista que no es de opciones (z.array de z.enum)");
      return { type: "choices", options: items };
    }
    case "object":
      return { type: "group", fields: fieldsOf(node, path) };
    default:
      throw new RecipeFormProblem("unsupported", place, `el tipo «${types[0]}»`);
  }
}

function optionsOf(node: JSONObject): FormOption[] | null {
  if (isObject(node.not) && Object.keys(node.not).length === 0) return [];
  const own = literalOptions(node);
  if (own) return own;
  const branches = Array.isArray(node.anyOf) ? node.anyOf : Array.isArray(node.oneOf) ? node.oneOf : null;
  if (!branches) return null;
  const options: FormOption[] = [];
  for (const branch of branches) {
    if (!isObject(branch) || JSON.stringify(typeNames(branch.type)) === JSON.stringify(["null"])) continue;
    const some = literalOptions(branch);
    if (!some) return null;
    options.push(...some);
  }
  return options;
}

function literalOptions(node: JSONObject): FormOption[] | null {
  if (Array.isArray(node.enum)) {
    const texts = node.enum.filter((value): value is string => typeof value === "string");
    return texts.length === node.enum.filter((value) => value !== null).length ? texts.map((value) => ({ value, label: value })) : null;
  }
  const constant = textOf(node.const);
  return constant === undefined ? null : [{ value: constant, label: textOf(node.title) ?? constant }];
}

export interface FormSection {
  path: string[];
  title: string | null;
  fields: FormField[];
}

export function recipeFormSections(form: RecipeForm): FormSection[] {
  return sections(form.fields, [], []);
}

function sections(fields: FormField[], path: string[], titles: string[]): FormSection[] {
  const result: FormSection[] = [];
  let leaves: FormField[] = [];
  const title = titles.length ? titles.join(" · ") : null;
  const close = () => {
    if (leaves.length) result.push({ path, title, fields: leaves });
    leaves = [];
  };
  for (const candidate of fields) {
    if (candidate.kind.type !== "group") {
      leaves.push(candidate);
      continue;
    }
    close();
    result.push(...sections(candidate.kind.fields, [...path, candidate.name], [...titles, candidate.label]));
  }
  close();
  return result;
}

export function valueAt(value: JSONValue | undefined, path: string[]): JSONValue | undefined {
  let current = value;
  for (const key of path) {
    if (!isObject(current)) return undefined;
    current = current[key];
  }
  return current;
}

export function setting(value: JSONValue | undefined, next: JSONValue | undefined, path: string[]): JSONValue {
  if (!path.length) return next === undefined ? (value ?? {}) : next;
  const [first, ...rest] = path;
  const fields: JSONObject = isObject(value) ? { ...value } : {};
  const child = rest.length ? setting(fields[first] ?? {}, next, rest) : next;
  if (child === undefined) delete fields[first];
  else fields[first] = child;
  return fields;
}

export function recipeFormIsVisible(field: FormField, values: JSONValue, parent: string[]) {
  if (!field.dependsOn) return true;
  return valueAt(values, [...parent, field.dependsOn]) === true;
}

function defaultsOf(fields: FormField[]): JSONObject {
  const result: JSONObject = {};
  for (const candidate of fields) {
    const value = defaultValue(candidate);
    if (value !== undefined) result[candidate.name] = value;
  }
  return result;
}

function defaultValue(field: FormField): JSONValue | undefined {
  if (field.kind.type !== "group") return field.defaultValue;
  if (isObject(field.defaultValue)) return overlay(defaultsOf(field.kind.fields), field.defaultValue);
  if (field.defaultValue === undefined) return defaultsOf(field.kind.fields);
  return field.defaultValue;
}

export function recipeFormDefaults(form: RecipeForm): JSONValue {
  return defaultsOf(form.fields);
}

function overlay(base: JSONValue, top: JSONValue | undefined): JSONValue {
  if (!isObject(base) || !isObject(top)) return top === undefined ? base : top;
  const fields: JSONObject = { ...base };
  for (const [name, change] of Object.entries(top)) fields[name] = name in fields ? overlay(fields[name], change) : change;
  return fields;
}

export function recipeFormValues(form: RecipeForm, saved: JSONValue | undefined): JSONValue {
  const base = recipeFormDefaults(form);
  if (!isObject(saved)) return base;
  const known = new Set(form.fields.map((candidate) => candidate.name));
  return overlay(base, Object.fromEntries(Object.entries(saved).filter(([name]) => known.has(name))));
}

export function equalValues(a: JSONValue | undefined, b: JSONValue | undefined): boolean {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((item, index) => equalValues(item, b[index]));
  if (isObject(a) && isObject(b)) {
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every((key) => key in b && equalValues(a[key], b[key]));
  }
  return false;
}

function overridesOf(fields: FormField[], values: JSONValue | undefined): JSONObject {
  const result: JSONObject = {};
  for (const candidate of fields) {
    const value = isObject(values) ? values[candidate.name] : undefined;
    if (candidate.kind.type === "group" && isObject(value)) {
      const inner = overridesOf(candidate.kind.fields, value);
      if (Object.keys(inner).length) result[candidate.name] = inner;
      else if (candidate.required && candidate.defaultValue === undefined) result[candidate.name] = {};
      continue;
    }
    if (value === undefined || equalValues(value, defaultValue(candidate))) continue;
    result[candidate.name] = value;
  }
  return result;
}

export function recipeFormOverrides(form: RecipeForm, values: JSONValue): JSONObject | null {
  const changes = overridesOf(form.fields, values);
  return Object.keys(changes).length ? changes : null;
}

export function recipeFormNumberText(number: number) {
  if (Number.isInteger(number) && Math.abs(number) < 1e15) return String(number);
  if (Math.abs(number) >= 1e15) return number.toExponential();
  return String(number);
}

export function recipeFormIssue(field: FormField, value: JSONValue | undefined): string | null {
  if (value === undefined) return field.required && field.defaultValue === undefined ? "falta un valor" : null;
  if (value === null) return field.nullable ? null : "falta un valor";
  switch (field.kind.type) {
    case "choice": {
      if (typeof value !== "string") return "no es una de las opciones";
      return field.kind.options.some((option) => option.value === value) ? null : `«${value}» ya no está entre las opciones`;
    }
    case "choices": {
      if (!Array.isArray(value)) return "no es una lista de opciones";
      const options = field.kind.options;
      const stale = value.filter((item): item is string => typeof item === "string").find((text) => !options.some((option) => option.value === text));
      return stale === undefined ? null : `«${stale}» ya no está entre las opciones`;
    }
    case "number": {
      if (typeof value !== "number") return "no es un número";
      const { minimum, maximum, integer } = field.kind;
      if (integer && !Number.isInteger(value)) return "tiene que ser un número entero";
      if (minimum !== null && maximum !== null && (value < minimum || value > maximum))
        return `tiene que estar entre ${recipeFormNumberText(minimum)} y ${recipeFormNumberText(maximum)}`;
      if (minimum !== null && value < minimum) return `tiene que ser ${recipeFormNumberText(minimum)} o más`;
      if (maximum !== null && value > maximum) return `tiene que ser ${recipeFormNumberText(maximum)} o menos`;
      return null;
    }
    default:
      return null;
  }
}

export function recipeFormNumberChoices(field: FormField): number[] | null {
  if (field.kind.type !== "number" || !field.kind.integer || field.kind.minimum === null || field.kind.maximum === null) return null;
  const { minimum, maximum } = field.kind;
  if (minimum > maximum || Math.abs(minimum) >= 1e9 || Math.abs(maximum) >= 1e9) return null;
  const from = Math.ceil(minimum);
  const to = Math.floor(maximum);
  if (to - from + 1 > maximumNumberChoices) return null;
  return Array.from({ length: to - from + 1 }, (_, index) => from + index);
}
