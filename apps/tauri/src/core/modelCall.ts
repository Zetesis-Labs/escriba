// What a recipe may send through escriba.modelo and what it gets back (ADR-0013).
// The controller enforces it: recipe code can reach the channel without the proxy.

const METHODS = ["doGenerate", "doStream"] as const;
export type ModelMethod = (typeof METHODS)[number];

const OPTIONS = new Set([
  "prompt",
  "maxOutputTokens",
  "temperature",
  "topP",
  "topK",
  "presencePenalty",
  "frequencyPenalty",
  "stopSequences",
  "seed",
  "responseFormat",
  "reasoning",
  "tools",
  "toolChoice",
]);
const PARTS: Record<string, readonly string[]> = {
  user: ["text"],
  assistant: ["text", "reasoning", "tool-call", "tool-result"],
  tool: ["tool-result", "tool-approval-response"],
};

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const defined = (value: Record<string, unknown>) => Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined));
function withoutProviderOptions(value: Record<string, unknown>, where: string) {
  if (value.providerOptions !== undefined) throw Error(`La receta no puede pasar providerOptions en ${where}`);
}

function message(raw: unknown): Record<string, unknown> {
  if (!isRecord(raw)) throw Error("Cada mensaje del prompt debe ser un objeto");
  const value = defined(raw);
  withoutProviderOptions(value, "un mensaje");
  if (value.role === "system") {
    if (typeof value.content !== "string") throw Error("El mensaje de sistema debe ser texto");
    return value;
  }
  const allowed = PARTS[String(value.role)];
  if (!allowed) throw Error(`Papel de mensaje no permitido: ${String(value.role)}`);
  if (!Array.isArray(value.content)) throw Error("El contenido del mensaje debe ser una lista");
  return {
    ...value,
    content: value.content.map((rawPart) => {
      if (!isRecord(rawPart)) throw Error("Cada parte del mensaje debe ser un objeto");
      const part = defined(rawPart);
      withoutProviderOptions(part, "una parte del mensaje");
      if (!allowed.includes(String(part.type))) throw Error(`La receta no puede mandar partes ${String(part.type)} al modelo`);
      return part;
    }),
  };
}

export function modelCall(raw: unknown): { method: ModelMethod; options: Record<string, unknown> } {
  if (!isRecord(raw)) throw Error("Llamada al modelo inválida");
  const method = raw.method as ModelMethod;
  if (!METHODS.includes(method)) throw Error(`El método del modelo no es válido: ${String(raw.method)}`);
  if (!isRecord(raw.options)) throw Error("Faltan las opciones de la llamada al modelo");
  const options = defined(raw.options);
  for (const key of Object.keys(options)) if (!OPTIONS.has(key)) throw Error(`La receta no puede pasar la opción ${key} al modelo`);
  if (!Array.isArray(options.prompt) || !options.prompt.length) throw Error("La llamada al modelo necesita un prompt");
  options.prompt = options.prompt.map(message);
  if (options.tools !== undefined) {
    if (!Array.isArray(options.tools)) throw Error("Las herramientas deben ser una lista");
    for (const tool of options.tools)
      if (!isRecord(tool) || tool.type !== "function") throw Error("La receta no puede usar herramientas del proveedor: solo las suyas");
  }
  return { method, options };
}

function withoutMetadata(value: unknown): unknown {
  if (!isRecord(value)) return value;
  const { providerMetadata: _metadata, ...rest } = value;
  return rest;
}

export function publicModelResult(raw: unknown): Record<string, unknown> {
  const result = isRecord(raw) ? raw : {};
  return {
    content: Array.isArray(result.content) ? result.content.map(withoutMetadata) : [],
    finishReason: result.finishReason,
    usage: result.usage,
    warnings: Array.isArray(result.warnings) ? result.warnings : [],
  };
}

export function publicModelParts(parts: readonly unknown[]): unknown[] {
  return parts.filter((part) => !isRecord(part) || part.type !== "raw").map(withoutMetadata);
}
