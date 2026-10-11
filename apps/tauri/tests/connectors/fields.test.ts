import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "vitest";
import type { ConnectorView, Provider } from "@escriba/conectores";
import { ConnectorEditor, ConnectorViewFields } from "../../src/connectors/ConnectorEditor";

describe("vista declarativa de un conector", () => {
  test("el proveedor externo muestra campos, opciones y acciones en el editor común", () => {
    const view: ConnectorView = {
      sections: [{
        title: "Proyecto",
        fields: [
          { type: "text", path: ["project"], label: "Nombre del proyecto" },
          { type: "select", path: ["board"], label: "Tablero", options: [{ label: "Equipo", value: { id: 42 } }] },
          { type: "select", path: [], value: "doc-1", label: "Documento", options: [{ label: "Acta", value: "doc-1" }] },
          { type: "action", id: "refresh-boards", label: "Actualizar tableros" },
          { type: "text", path: ["property", "key"], label: "Clave", row: "property-1" },
          { type: "text", path: ["property", "value"], label: "Valor", row: "property-1" },
          { type: "action", id: "remove-property", label: "Quitar", row: "property-1" },
        ],
      }],
    };
    const markup = renderToStaticMarkup(createElement(ConnectorViewFields, { view, configuration: { project: "Prueba", board: { id: 42 } }, onChange: () => undefined, onAction: () => undefined, home: null }));
    expect(markup).toContain("Nombre del proyecto");
    expect(markup).toContain("Prueba");
    expect(markup).toContain("Equipo");
    expect(markup).toContain("Acta");
    expect(markup).toContain("Actualizar tableros");
    expect(markup.match(/connector-grouped-fields/g)).toHaveLength(1);
  });

  test("un proveedor ausente conserva una explicación visible en su destino", () => {
    const markup = renderToStaticMarkup(createElement(ConnectorEditor, {
      destination: { id: "d", name: "Antiguo", provider: "ausente", account: "d", enabled: false, configuration: { key: "dato" } },
      refresh: async () => undefined,
      home: null,
    }));
    expect(markup).toContain("Proveedor no disponible");
    expect(markup).toContain("ausente");
  });

  test("un proveedor HTTP sin credencial muestra origen y autorización antes de guardar", () => {
    const provider: Provider = { id: "public-api", name: "API", capability: "http", origin: "https://api.example.test", allowedHeaders: [], defaultConfiguration: {} };
    const markup = renderToStaticMarkup(createElement(ConnectorEditor, {
      account: { id: "a", name: "API", provider: provider.id, enabled: false },
      destination: { id: "a", name: "API", provider: provider.id, account: "a", enabled: false, configuration: {}, managed: true },
      provider, refresh: async () => undefined, home: null,
    }));
    expect(markup).toContain("Acceso solicitado a https://api.example.test");
    expect(markup).toContain("Autorizar acceso");
  });

  test("un cambio de carpeta muestra el nuevo alcance y exige autorizarlo", () => {
    const provider: Provider = { id: "files", name: "Archivos", capability: "folder", allowedHeaders: [], defaultConfiguration: { folder: "/nuevo" } };
    const markup = renderToStaticMarkup(createElement(ConnectorEditor, {
      account: { id: "f", name: "Archivos", provider: provider.id, enabled: true, folder: "/viejo", grant: { capability: "folder", allowedHeaders: [] } },
      destination: { id: "f", name: "Archivos", provider: provider.id, account: "f", enabled: false, configuration: { folder: "/nuevo" }, managed: true },
      provider, refresh: async () => undefined, home: null,
    }));
    expect(markup).toContain("Acceso solicitado a la carpeta /nuevo");
    expect(markup).toContain("El alcance solicitado ha cambiado");
    expect(markup).toContain("Autorizar acceso");
  });
});
