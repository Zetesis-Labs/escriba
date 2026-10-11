import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { NoteDataEditor } from "../../src/library/NoteDataEditor";

test("muestra cada tipo guardado y usa los títulos del esquema sin editor JSON", () => {
  const markup = renderToStaticMarkup(createElement(NoteDataEditor, {
    value: { asunto: "Una idea", prioridad: 2, listo: false, etiquetas: ["voz"] },
    schema: { type: "object", properties: { asunto: { type: "string", title: "Asunto" }, prioridad: { type: "number", title: "Prioridad" }, listo: { type: "boolean", title: "Terminada" }, etiquetas: { type: "array", title: "Etiquetas", items: { type: "string" } } } },
    onChange: () => undefined,
  }));
  expect(markup).toContain("Asunto");
  expect(markup).toContain("Prioridad");
  expect(markup).toContain("Terminada");
  expect(markup).toContain("Etiquetas");
  expect(markup).toContain("Añadir elemento");
  expect(markup).toContain('inputMode="decimal"');
  expect(markup).toContain('type="checkbox"');
  expect(markup).not.toContain("<pre");
});

test("un campo opcional conocido se puede añadir y un dato ausente sin esquema se explica", () => {
  const markup = renderToStaticMarkup(createElement(NoteDataEditor, {
    value: {}, schema: { type: "object", properties: { lugar: { type: "string", title: "Lugar" } } }, onChange: () => undefined,
  }));
  expect(markup).toContain("Añadir lugar");
  const empty = renderToStaticMarkup(createElement(NoteDataEditor, { value: null, onChange: () => undefined }));
  expect(empty).toContain("La receta no guardó datos.");
});

test("las opciones del esquema se presentan como selección tipada", () => {
  const markup = renderToStaticMarkup(createElement(NoteDataEditor, {
    value: null, schema: { enum: [null, "Borrador", "Final"] }, onChange: () => undefined,
  }));
  expect(markup).toContain("<select");
  expect(markup).toContain("Borrador");
  expect(markup).toContain("Final");
});

test("los enteros exigen entrada entera y las listas enum vacías admiten añadir", () => {
  const markup = renderToStaticMarkup(createElement(NoteDataEditor, {
    value: { prioridad: 2, estados: [] },
    schema: { type: "object", properties: {
      prioridad: { type: "integer", title: "Prioridad" },
      estados: { type: "array", title: "Estados", items: { enum: ["Pendiente", "Hecho"] } },
    } },
    onChange: () => undefined,
  }));
  expect(markup).toContain('inputMode="numeric"');
  expect(markup).toContain('pattern="-?\\d+"');
  expect(markup).toContain("Añadir elemento</button>");
  expect(markup).not.toContain("Tipo de nuevo elemento en Estados");
});
