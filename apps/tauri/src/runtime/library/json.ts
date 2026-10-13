import { createHash, randomUUID } from "node:crypto";
import type { JSONObject, JSONValue } from "../../types";

export type Json = JSONValue;
export type JsonObject = JSONObject;

export const isObject = (value: unknown): value is Record<string, Json> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isObject(value)) {
    const keys = Object.keys(value).filter((key) => value[key] !== undefined).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value === undefined ? null : value);
}
export const equal = (left: unknown, right: unknown) => canonical(left) === canonical(right);
export const clone = <T>(value: T): T => (value === undefined ? value : (JSON.parse(JSON.stringify(value)) as T));
export const sha256 = (data: string | Uint8Array) => createHash("sha256").update(data).digest("hex");
export const newId = () => randomUUID();
const pad = (value: number, width = 2) => String(value).padStart(width, "0");
const stamp = (date: Date, fraction: string) =>
  `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}T${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}${fraction}+00:00`;
export function rfc3339(date: Date = new Date()): string {
  const millis = date.getUTCMilliseconds();
  return stamp(date, millis ? `.${pad(millis, 3)}` : "");
}
let lastMicros = 0;
export function now(): string {
  const micros = Math.max(Date.now() * 1000, lastMicros + 1);
  lastMicros = micros;
  const fraction = micros % 1_000_000;
  return stamp(new Date(Math.floor(micros / 1000)), fraction ? `.${pad(fraction, 6)}` : "");
}
export function text(value: unknown, key: string): string {
  const field = isObject(value) ? value[key] : undefined;
  if (typeof field !== "string" || !field) throw Error(`Falta ${key}`);
  return field;
}
export function field(value: unknown, key: string): Json | undefined {
  return isObject(value) ? value[key] : undefined;
}
export function array(value: unknown, message: string): Json[] {
  if (!Array.isArray(value)) throw Error(message);
  return value;
}
export function object(value: unknown, message: string): Record<string, Json> {
  if (!isObject(value)) throw Error(message);
  return value;
}
export function safeId(value: string): string {
  if (!value || value.length >= 200 || !/^[A-Za-z0-9._-]+$/.test(value) || value === "." || value === "..")
    throw Error("Identificador no válido");
  return value;
}
