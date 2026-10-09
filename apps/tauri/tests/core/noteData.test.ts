import { describe, expect, test } from "vitest";
import { dataRows } from "../../src/core/noteData";

const text = (label: string, depth: number, value: string) => ({ label, depth, value: { kind: "text", text: value } });
const group = (label: string, depth: number) => ({ label, depth, value: { kind: "group" } });

describe("los datos de la nota en el detalle", () => {
  test("el detalle pinta cada campo en su orden, con listas, grupos y sí o no, y se salta lo vacío", () => {
    const datos = JSON.parse(
      '{"cliente":"Acme","urgente":false,"importe":12.5,"personas":3,"tareas":["llamar",null],"contacto":{"nombre":"Ana","email":null},"vacia":[],"nada":{},"reunion":null,"sinNada":{"a":null,"b":[]},"pasos":[{"hecho":true}]}',
    );
    expect(dataRows(datos)).toEqual([
      text("cliente", 0, "Acme"),
      text("urgente", 0, "no"),
      text("importe", 0, "12,5"),
      text("personas", 0, "3"),
      { label: "tareas", depth: 0, value: { kind: "list", items: ["llamar", "—"] } },
      group("contacto", 0),
      text("nombre", 1, "Ana"),
      group("pasos 1", 0),
      text("hecho", 1, "sí"),
    ]);
  });
  test("unos datos sin nada que enseñar no dan ninguna fila", () => {
    expect(dataRows(JSON.parse('{"a":null,"b":[],"c":{"d":null}}'))).toEqual([]);
  });
  test("con el esquema guardado, cada campo usa su title de Zod, también dentro de nulos, grupos y listas", () => {
    const esquema = JSON.parse(
      '{"type":"object","properties":{"enUnaFrase":{"type":"string","title":"En una frase"},"reunion":{"anyOf":[{"type":"object","properties":{"tareas":{"type":"array","items":{"type":"object","properties":{"que":{"type":"string","title":"Qué"}}},"title":"Tareas"}}},{"type":"null"}],"title":"Reunión"},"idea":{"anyOf":[{"type":"object","properties":{"titulo":{"type":"string"}},"title":"Idea"},{"type":"null"}]},"sin":{"type":"string"}}}',
    );
    const datos = JSON.parse('{"enUnaFrase":"Hola","reunion":{"tareas":[{"que":"llamar"}]},"idea":{"titulo":"T"},"sin":"x","extra":1}');
    expect(dataRows(datos, esquema)).toEqual([
      text("En una frase", 0, "Hola"),
      group("Reunión", 0),
      group("Tareas 1", 1),
      text("Qué", 2, "llamar"),
      group("Idea", 0),
      text("titulo", 1, "T"),
      text("sin", 0, "x"),
      text("extra", 0, "1"),
    ]);
  });
});
