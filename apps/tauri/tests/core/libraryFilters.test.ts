import { describe, expect, it } from "vitest";
import { conditionText, conditionValue, defaultCondition, filterFields, filterOperators, filterRecordLabel } from "../../src/core/libraryFilters";
import type { OntologyDefinition } from "../../src/knowledge/model";

const catalog: OntologyDefinition[] = [{ id: "base", name: "Base", version: 1, migrations: [], collections: [
  { table: "edge", label: "Relación", titleField: "id", fields: [], relation: { from: "person", to: "recording" } },
  { table: "thing", label: "Entidad", titleField: "name", fields: [{ key: "amount", label: "Importe", type: "number" }, { key: "active", label: "Activo", type: "boolean" }] },
] }];

describe("filtros de Biblioteca", () => {
  it.each(["123", "null", "true", "urgente", "", null, false, 1.5, { estado: "abierto" }, ["uno", 2]])("conserva el tipo JSON al editar y volver a guardar %j", (value) => {
    const field = { key: "tags", label: "Etiquetas", type: "json" as const };
    expect(conditionValue(field, "eq", conditionText(field, value))).toEqual(value);
    expect(conditionValue(field, "contains", conditionText(field, value))).toEqual(value);
  });
  it("permite identidad en cualquier colección y extremos en relaciones", () => {
    expect(filterFields(catalog[0].collections[0], "base").map((field) => field.key)).toEqual(["id", "in", "out"]);
    expect(defaultCondition(catalog)?.field).toBe("id");
    expect(defaultCondition([{ ...catalog[0], collections: [catalog[0].collections[1]] }])?.field).toBe("amount");
  });
  it("trata la versión vigente como identidad nativa de la base", () => {
    const recording = { table: "recording", label: "Grabaciones", titleField: "title", fields: [{ key: "currentVersion", label: "Versión vigente", type: "json" as const }] };
    const field = filterFields(recording, "escriba").find((item) => item.key === "currentVersion")!;
    expect(field.recordTarget).toEqual({ ontologyId: "escriba", table: "version", value: "id" });
    expect(filterOperators(field).map((item) => item.value)).toEqual(["eq", "ne", "empty", "notEmpty"]);
    expect(conditionValue(field, "eq", 'version:["rec-1","v2"]')).toBe('version:["rec-1","v2"]');
  });
  it("recupera etiquetas de los dos extremos de una relación sin título, una sola vez", async () => {
    const ontology: OntologyDefinition = { id: "crm", name: "CRM", version: 1, migrations: [], collections: [
      { table: "cliente", label: "Clientes", titleField: "nombre", fields: [{ key: "nombre", label: "Nombre", type: "text" }] },
      { table: "colabora", label: "Colabora", titleField: "proyecto", relation: { from: "cliente", to: "cliente" }, fields: [{ key: "proyecto", label: "Proyecto", type: "text" }] },
    ] };
    const loaded: string[] = [];
    const load = async (id: string) => { loaded.push(id); return { nombre: id === "cliente:a" ? "Aurora" : "Norte" }; };
    const relation = ontology.collections[1];
    expect(await filterRecordLabel(ontology, relation, { in: "cliente:a", out: "cliente:b" }, load)).toBe("Aurora → Norte");
    expect(loaded).toEqual(["cliente:a", "cliente:b"]);
    expect(await filterRecordLabel(ontology, relation, { proyecto: "Alianza", in: "cliente:a", out: "cliente:b" }, load)).toBe("Alianza");
    expect(loaded).toHaveLength(2);
  });
  it("limita operadores y convierte valores según el tipo", () => {
    const number = catalog[0].collections[1].fields[0];
    const boolean = catalog[0].collections[1].fields[1];
    expect(filterOperators(number).map((choice) => choice.value)).toContain("gte");
    expect(filterOperators(boolean).map((choice) => choice.value)).not.toContain("contains");
    expect(filterOperators(filterFields(catalog[0].collections[0], "base")[0]).map((choice) => choice.value)).not.toContain("contains");
    expect(conditionValue(number, "gte", "12,5")).toBe(12.5);
    expect(conditionValue(boolean, "eq", "false")).toBe(false);
    expect(conditionValue(number, "empty", "")).toBeUndefined();
    expect(conditionValue({ key: "fecha", label: "Fecha", type: "date" }, "eq", "2026-10-11")).toBe("2026-10-11");
    expect(conditionValue({ key: "tags", label: "Etiquetas", type: "json" }, "contains", "urgente")).toBe("urgente");
    expect(() => conditionValue(number, "eq", "abc")).toThrow("número");
  });
});
