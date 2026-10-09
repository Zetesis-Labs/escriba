import { run } from "@escriba/conectores";
import { expect, test } from "vitest";
import { notionPreview } from "../../src/core/notionPreview";

const source = {
  id: "s", title: "Notas", databaseTitle: "Notas",
  properties: [
    { name: "Hablantes", type: "multi_select" },
    { name: "Nombre", type: "title" },
    { name: "Temas", type: "multi_select" },
  ],
};

test("enseña cada columna y el cuerpo como quedarían en la página de Swift", async () => {
  const result = await run({ operation: "preview", provider: "notion", config: {
    source,
    columns: { Nombre: "{{titulo}}", Hablantes: "{{hablantes}}", Temas: "{{etiquetas}}" },
    body: "# Resumen\n{{resumen}}\n- {{hablantes}}\n{{audio}}\n{{transcripcion}}",
  } });
  const preview = notionPreview(result, source);
  expect(preview.properties).toEqual([
    { name: "Nombre", value: "Lanzamiento del jueves" },
    { name: "Hablantes", value: "Ana, Luis" },
    { name: "Temas", value: "lanzamiento, migración" },
  ]);
  expect(preview.text).toMatch(/^# Resumen\n\nAna y Luis repasan/);
  expect(preview.text).toContain("• Ana, Luis\n\n▶︎ Audio\n\nAna: ¿Cómo vamos");
});

test("una columna que se vacía se ve como raya y las columnas sin plantilla no aparecen", async () => {
  const withEmpty = { ...source, properties: [...source.properties, { name: "Estado", type: "select" }] };
  const result = await run({ operation: "preview", provider: "notion", config: {
    source: withEmpty, columns: { Nombre: "{{titulo}}", Estado: "{{enlace:x}}" }, body: "",
  } });
  expect(notionPreview(result, withEmpty).properties).toEqual([
    { name: "Nombre", value: "Lanzamiento del jueves" }, { name: "Estado", value: "—" },
  ]);
});

test("presenta fechas, números, URL y texto sin el formato de transporte", () => {
  const properties = {
    Fecha: { date: { start: "2026-10-09T12:00:00Z" } },
    Segundos: { number: 29 },
    Medida: { number: 1.5 },
    URL: { url: "https://example.com" },
    Estado: { select: { name: "Lista" } },
    Texto: { rich_text: [{ text: { content: "Hola " } }, { text: { content: "mundo" } }] },
    Vacío: { number: null },
  };
  expect(notionPreview({ properties }, { properties: Object.keys(properties).map((name) => ({ name, type: "rich_text" })) }).properties.map((property) => property.value))
    .toEqual(["2026-10-09T12:00:00Z", "29", "1.5", "https://example.com", "Lista", "Hola mundo", "—"]);
});
