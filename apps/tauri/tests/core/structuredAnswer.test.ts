import { test } from "vitest";
import assert from "node:assert/strict";
import { answerJson } from "../../src/core/structuredAnswer";

const resumen = { title: "T", summary: "S", tags: ["a"] };
const texto = JSON.stringify(resumen);

test("una respuesta que ya es JSON se lee tal cual", () => {
  assert.deepEqual(answerJson(texto), resumen);
  assert.deepEqual(answerJson(`  ${texto}\n`), resumen);
  assert.deepEqual(answerJson("[1,2]"), [1, 2]);
});

test("el JSON dentro de un bloque de código se lee, con o sin lenguaje", () => {
  assert.deepEqual(answerJson("```json\n" + texto + "\n```"), resumen);
  assert.deepEqual(answerJson("```\n" + texto + "\n```"), resumen);
  assert.deepEqual(answerJson("```JSON " + texto + "```"), resumen);
});

test("el JSON rodeado de texto se lee aunque no lleve bloque", () => {
  assert.deepEqual(answerJson(`Aquí tienes el resumen:\n${texto}\nEspero que sirva.`), resumen);
  assert.deepEqual(answerJson(`Aquí tienes:\n\`\`\`json\n${texto}\n\`\`\`\nUn saludo.`), resumen);
});

test("las llaves dentro de un texto no cortan el objeto", () => {
  const raro = { title: "Llaves } y { dentro", summary: 'Comillas \\" y ] corchete', tags: [] };
  assert.deepEqual(answerJson(`Respuesta: ${JSON.stringify(raro)} fin`), raro);
});

test("se toma el primer valor completo que sea JSON válido", () => {
  assert.deepEqual(answerJson("Ejemplo {no es json} y luego " + texto), resumen);
});

test("sin JSON en la respuesta no hay valor", () => {
  assert.equal(answerJson("No sé hacer JSON"), undefined);
  assert.equal(answerJson(""), undefined);
  assert.equal(answerJson('{"title": "sin cerrar"'), undefined);
});
