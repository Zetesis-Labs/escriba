import { z } from "zod";
import type { ConnectorEditorResult } from "@escriba/conectores";

const configuration = z.record(z.string(), z.json());
const field = z.object({
  type: z.enum(["text", "textarea", "number", "boolean", "select", "template", "folder"]),
  path: z.array(z.union([z.string().refine((key) => !["__proto__", "constructor", "prototype"].includes(key)), z.number().int().min(0).max(9999)])).max(32),
  label: z.string(),
  row: z.string().optional(),
  help: z.string().optional(),
  placeholder: z.string().optional(),
  disabled: z.boolean().optional(),
  options: z.array(z.object({ label: z.string(), value: z.json() })).optional(),
  value: z.json().optional(),
  action: z.string().optional(),
  context: z.enum(["path", "property", "body"]).optional(),
  multiline: z.boolean().optional(),
  links: z.array(z.object({ id: z.string(), name: z.string() })).optional(),
  current: z.string().optional(),
});
const action = z.object({
  type: z.literal("action"), id: z.string(), label: z.string(),
  row: z.string().optional(),
  disabled: z.boolean().optional(), destructive: z.boolean().optional(),
});
const resultSchema = z.object({
  configuration: configuration.optional(),
  state: configuration.optional(),
  valid: z.boolean().optional(),
  problem: z.string().optional(),
  view: z.object({
    sections: z.array(z.object({
      title: z.string().optional(), help: z.string().optional(),
      fields: z.array(z.union([field, action])),
    })),
    problem: z.string().optional(),
    subtitle: z.string().optional(),
    previews: z.array(z.object({
      title: z.string().optional(), text: z.string().optional(),
      properties: z.array(z.object({ label: z.string(), value: z.string() })).optional(),
    })).optional(),
  }).optional(),
});

export function connectorEditorResult(value: unknown): ConnectorEditorResult {
  const result = resultSchema.safeParse(value);
  if (!result.success) throw Error(`El proveedor devolvió un formulario inválido: ${result.error.message}`);
  return result.data;
}
