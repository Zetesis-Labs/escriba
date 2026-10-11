import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { LibraryFilters } from "../../src/library/LibraryFilters";
import type { LibraryFiltersController } from "../../src/library/useLibraryFilters";
import type { SavedLibraryFilter } from "../../src/core/libraryFilters";

const controller: LibraryFiltersController = {
  saved: [], savedError: null, catalogError: null, catalogLoading: false, selectedSavedId: null,
  catalog: [{ id: "escriba", name: "Escriba", version: 1, builtIn: true, migrations: [], collections: [
    { table: "person", label: "Personas", titleField: "name", fields: [{ key: "name", label: "Nombre", type: "text" }] },
  ] }],
  result: { filter: { kind: "visual", match: "any", conditions: [
    { ontologyId: "escriba", table: "person", field: "name", operator: "contains", value: "Ana" },
  ] }, ids: new Set(), loading: false, error: null, name: null },
  loadCatalog: async () => {}, apply: async () => {}, clear: () => {}, selectSaved: () => {},
  save: async () => { throw new Error("El render no guarda filtros"); }, remove: async () => {},
};

test("un filtro visual ofrece nombre y guardado junto a sus condiciones", () => {
  const html = renderToStaticMarkup(createElement(LibraryFilters, { controller, editing: null, onClose: () => {} }));
  expect(html).toContain("Nombre para guardar");
  expect(html).toMatch(/>Guardar<\/button>/);
  expect(html).toContain('value="Ana"');
});

test("editar un visual guardado recupera sus condiciones y combinación aunque haya otra consulta activa", () => {
  const editing: SavedLibraryFilter = { id: "visual", name: "Equipo", filter: { kind: "visual", match: "any", conditions: [
    { ontologyId: "escriba", table: "person", field: "name", operator: "contains", value: "Luis" },
    { ontologyId: "escriba", table: "person", field: "name", operator: "eq", value: "Ana" },
  ] } };
  const html = renderToStaticMarkup(createElement(LibraryFilters, { controller: { ...controller,
    result: { filter: { kind: "surrealql", ontologyId: "escriba", sql: "SELECT id FROM person" }, ids: new Set<string>(), loading: false, error: null, name: "Otra consulta" },
  }, editing, onClose: () => {} }));
  expect(html).toMatch(/aria-checked="true"[^>]*>Visual<\/button>/);
  expect(html).toMatch(/aria-checked="true"[^>]*>Cualquiera<\/button>/);
  expect(html).toContain('value="Luis"');
  expect(html).toContain('value="Ana"');
  expect(html).toContain('value="Equipo"');
  expect(html).toContain('<option value="contains" selected="">');
  expect(html).toContain('<option value="eq" selected="">');
  expect(html).not.toContain("SELECT id FROM person");
});

test("editar SurrealQL mantiene su modo y texto aunque haya un filtro visual activo", () => {
  const editing: SavedLibraryFilter = { id: "sql", name: "Personas", filter: { kind: "surrealql", ontologyId: "escriba", sql: "SELECT id FROM person" } };
  const html = renderToStaticMarkup(createElement(LibraryFilters, { controller, editing, onClose: () => {} }));
  expect(html).toMatch(/aria-checked="true"[^>]*>SurrealQL<\/button>/);
  expect(html).toContain("SELECT id FROM person");
  expect(html).toContain('value="Personas"');
  expect(html).toMatch(/>Guardar<\/button>/);
  expect(html).not.toContain("Mostrar notas que cumplen");
});

test.each([["123", "&quot;123&quot;"], [null, "null"]])("editar un criterio JSON presenta %j sin perder su tipo", (value, displayed) => {
  const editing: SavedLibraryFilter = { id: "json", name: "Etiquetas", filter: { kind: "visual", match: "all", conditions: [
    { ontologyId: "escriba", table: "version", field: "tags", operator: "eq", value },
  ] } };
  const html = renderToStaticMarkup(createElement(LibraryFilters, { controller: { ...controller, catalog: [
    { ...controller.catalog[0], collections: [{ table: "version", label: "Versiones", titleField: "tags", fields: [{ key: "tags", label: "Etiquetas", type: "json" }] }] },
  ] }, editing, onClose: () => {} }));
  expect(html).toContain(`value="${displayed}"`);
});
