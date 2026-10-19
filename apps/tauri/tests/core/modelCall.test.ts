import { test } from "vitest";
import assert from "node:assert/strict";
import { modelCall, publicModelParts, publicModelResult } from "../../src/core/modelCall";

const prompt = [
  { role: "system", content: "Eres breve." },
  { role: "user", content: [{ type: "text", text: "¿Cuántas palabras?" }] },
  { role: "assistant", content: [{ type: "reasoning", text: "pienso" }, { type: "tool-call", toolCallId: "1", toolName: "contar", input: { texto: "hola" } }] },
  { role: "tool", content: [{ type: "tool-result", toolCallId: "1", toolName: "contar", output: { type: "json", value: { palabras: 1 } } }] },
];
const tool = { type: "function", name: "contar", description: "Cuenta palabras", inputSchema: { type: "object", properties: { texto: { type: "string" } } } };

test("una llamada con las opciones permitidas pasa entera y se puede serializar", () => {
  const options = {
    prompt,
    maxOutputTokens: 100,
    temperature: 0.2,
    topP: 1,
    topK: 4,
    presencePenalty: 0,
    frequencyPenalty: 0,
    stopSequences: ["FIN"],
    seed: 7,
    reasoning: "low",
    responseFormat: { type: "json", schema: { type: "object" } },
    tools: [tool],
    toolChoice: { type: "auto" },
  };
  assert.deepEqual(modelCall({ method: "doGenerate", options }), { method: "doGenerate", options });
  assert.equal(modelCall({ method: "doStream", options: { prompt } }).method, "doStream");
});

test("las opciones que no estén permitidas se rechazan nombrándolas", () => {
  for (const key of ["headers", "providerOptions", "includeRawChunks", "abortSignal", "baseURL"])
    assert.throws(() => modelCall({ method: "doGenerate", options: { prompt, [key]: {} } }), new RegExp(key));
  assert.deepEqual(modelCall({ method: "doGenerate", options: { prompt, headers: undefined } }).options, { prompt });
  assert.throws(() => modelCall({ method: "doEmbed", options: { prompt } }), /método/);
  assert.throws(() => modelCall({ method: "doGenerate", options: {} }), /prompt/);
});

test("las herramientas del proveedor y los archivos en el prompt no salen de la receta", () => {
  assert.throws(() => modelCall({ method: "doGenerate", options: { prompt, tools: [{ type: "provider", id: "anthropic.web_search", name: "buscar", args: {} }] } }), /herramientas del proveedor/);
  const archivo = [{ role: "user", content: [{ type: "file", mediaType: "image/png", data: "AAAA" }] }];
  assert.throws(() => modelCall({ method: "doGenerate", options: { prompt: archivo } }), /file/);
  assert.throws(() => modelCall({ method: "doGenerate", options: { prompt: [{ role: "user", content: [{ type: "text", text: "x", providerOptions: { a: {} } }] }] } }), /providerOptions/);
  assert.throws(() => modelCall({ method: "doGenerate", options: { prompt: [{ role: "developer", content: "x" }] } }), /Papel/);
});

test("a la receta solo vuelven el contenido, el motivo de fin, el uso y los avisos", () => {
  const result = {
    content: [{ type: "text", text: "hola", providerMetadata: { openai: { id: "x" } } }],
    finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 1 }, outputTokens: { total: 2 } },
    warnings: [],
    providerMetadata: { openai: { organization: "org-123" } },
    request: { body: "{}" },
    response: { headers: { "openai-organization": "org-123" }, body: {} },
  };
  assert.deepEqual(publicModelResult(result), {
    content: [{ type: "text", text: "hola" }],
    finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 1 }, outputTokens: { total: 2 } },
    warnings: [],
  });
});

test("las partes de un stream pierden los metadatos del proveedor y las tramas en bruto", () => {
  const parts = [
    { type: "stream-start", warnings: [] },
    { type: "response-metadata", id: "r", modelId: "m" },
    { type: "raw", rawValue: { secreto: true } },
    { type: "text-delta", id: "1", delta: "ho", providerMetadata: { x: 1 } },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: {}, providerMetadata: { x: 1 } },
  ];
  assert.deepEqual(publicModelParts(parts), [
    { type: "stream-start", warnings: [] },
    { type: "response-metadata", id: "r", modelId: "m" },
    { type: "text-delta", id: "1", delta: "ho" },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: {} },
  ]);
});
