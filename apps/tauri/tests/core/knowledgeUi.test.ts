import { describe, expect, test } from "vitest";
import { candidateStatus, editedFields, fieldInputText, isDefinition, isInstalledOntology, isRecordPage, parseField, recordTitle } from "../../src/knowledge/model";

const collection = { table: "personas", label: "Personas", titleField: "nombre", fields: [{ key: "nombre", label: "Nombre", type: "text" as const, required: true }] };

describe("ontologías en la interfaz", () => {
  test("propone instalar o actualizar por identidad y versión, conservando las instaladas ausentes del proyecto", () => {
    const installed = [{ id: "crm", name: "CRM anterior", version: 2, migrations: [], collections: [collection] }, { id: "archivo", name: "Archivo", version: 1, migrations: [], collections: [collection] }];
    expect(candidateStatus({ id: "crm", name: "CRM", version: 3, migrations: [], collections: [collection] }, installed)).toBe("update");
    expect(candidateStatus({ id: "nuevo", name: "CRM", version: 1, migrations: [], collections: [collection] }, installed)).toBe("install");
    expect(candidateStatus({ id: "crm", name: "CRM anterior", version: 2, migrations: [], collections: [collection] }, installed)).toBe("current");
    expect(candidateStatus({ id: "crm", name: "CRM anterior", version: 2, migrations: [], collections: [{ ...collection, fields: [{ key: "nombre", label: "Nombre", type: "text", required: true }] }] }, installed)).toBe("current");
    expect(candidateStatus({ id: "archivo", name: "Archivo", version: 1, migrations: [], collections: [{ ...collection, fields: [{ key: "nombre", label: "Nombre", type: "text", required: false }] }] }, [{ ...installed[1], collections: [{ ...collection, fields: [{ key: "nombre", label: "Nombre", type: "text" }] }] }])).toBe("current");
    expect(candidateStatus({ id: "crm", name: "CRM distinto", version: 2, migrations: [], collections: [collection] }, installed)).toBe("conflict");
    expect(candidateStatus({ id: "crm", name: "CRM", version: 1, migrations: [], collections: [collection] }, installed)).toBe("older");
    expect(installed.map((item) => item.id)).toEqual(["crm", "archivo"]);
  });

  test("convierte tipos declarados y rechaza los valores incorrectos nombrando el campo", () => {
    expect(parseField({ key: "coste", label: "Coste", type: "number" }, "12,5")).toBe(12.5);
    expect(parseField({ key: "hecho", label: "Hecho", type: "boolean" }, true)).toBe(true);
    expect(parseField({ key: "datos", label: "Datos", type: "json" }, "{\"a\":1}")).toEqual({ a: 1 });
    expect(parseField({ key: "datos", label: "Datos", type: "json" }, " ")).toBeUndefined();
    expect(parseField({ key: "fecha", label: "Fecha", type: "date" }, "2026-10-14")).toBe("2026-10-14T00:00:00.000Z");
    expect(fieldInputText({ key: "fecha", label: "Fecha", type: "date" }, "2026-10-14T00:00:00.000Z")).toBe("2026-10-14");
    expect(() => parseField({ key: "fecha", label: "Fecha", type: "date" }, "2026-02-31")).toThrow("Fecha");
    expect(() => parseField({ key: "coste", label: "Coste", type: "number" }, "doce")).toThrow("Coste");
    expect(() => parseField({ key: "nombre", label: "Nombre", type: "text", required: true }, "  ")).toThrow("Nombre");
  });

  test("usa el título declarado, sin inventar un formulario para campos ausentes", () => {
    expect(recordTitle(collection, { nombre: "Ada", otros: "oculto" })).toBe("Ada");
    expect(recordTitle(collection, { otros: "oculto" })).toBe("Registro");
  });

  test("editar un título conserva los tipos y la precisión de los campos no tocados", () => {
    const fields = [
      ...collection.fields,
      { key: "fecha", label: "Fecha", type: "date" as const },
      { key: "datos", label: "Datos", type: "json" as const },
      { key: "activo", label: "Activo", type: "boolean" as const },
    ];
    const original = { nombre: "Ada", fecha: "2026-10-14T13:41:23.123+02:00", datos: "hello" };
    const raw = { nombre: "Otro nombre", fecha: "2026-10-14", datos: fieldInputText(fields[2], original.datos), activo: false };
    expect(raw.datos).toBe('"hello"');
    expect(fieldInputText(fields[2], null)).toBe("null");
    expect(editedFields({ ...collection, fields }, raw, original)).toEqual({ ...original, nombre: "Otro nombre" });
    expect(editedFields({ ...collection, fields }, { ...raw, fecha: "2026-10-15", datos: '"changed"' }, original)).toEqual({ nombre: "Otro nombre", fecha: "2026-10-15T00:00:00.000Z", datos: "changed" });
  });

  test("no acepta páginas incompletas como registros editables", () => {
    expect(isRecordPage(null)).toBe(false);
    expect(isRecordPage({ page: 0, hasMore: false, records: [null] })).toBe(false);
    expect(isRecordPage({ page: 0, hasMore: false, records: [{ id: "personas:1", ontologyId: "crm", table: "personas", rev: "abc", values: null }] })).toBe(false);
    expect(isRecordPage({ page: 0, hasMore: false, records: [{ id: "personas:1", ontologyId: "crm", table: "personas", values: { nombre: "Ada" } }] })).toBe(false);
    expect(isRecordPage({ page: 0, hasMore: false, records: [{ id: "personas:1", ontologyId: "crm", table: "personas", rev: "abc", values: { nombre: "Ada" } }] })).toBe(true);
    expect(isDefinition({ id: "crm", name: "CRM", version: 1, migrations: [], collections: [{ ...collection, relation: { from: "personas" } }] })).toBe(false);
    expect(isInstalledOntology({ id: "crm", name: "CRM", version: 1, migrations: [], collections: [null] })).toBe(false);
  });
});
