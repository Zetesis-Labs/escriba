import { describe, expect, test } from "vitest";
import {
  chooseNotionSource,
  connectorProblem,
  connectorSubtitle,
  makeConnector,
  newOKFDocument,
  nextConnectorName,
  notionConfiguration,
  okfProblem,
  removeOKFProperty,
  writableColumns,
} from "../../src/core/connectors";

const source = {
  id: "ds-1",
  title: "Notas",
  databaseTitle: "Diario",
  properties: [
    { name: "Hecho", type: "checkbox" },
    { name: "Fecha", type: "date" },
    { name: "Nombre", type: "title" },
    { name: "Clave", type: "rich_text" },
  ],
};

describe("conectores como en la app Swift", () => {
  test("varios conectores reciben nombres distintos y una cuenta y destino con el mismo id", () => {
    expect(nextConnectorName("notion", ["Notion", "Notion 2", "OKF"])).toBe("Notion 3");
    const created = makeConnector("okf", "conector-1", "OKF");
    expect(created.account.id).toBe("conector-1");
    expect(created.destination.id).toBe("conector-1");
    expect(created.destination.account).toBe("conector-1");
    expect(created.destination.enabled).toBe(false);
    expect(created.destination.program).toBeUndefined();
    expect(created.destination.configuration.documents?.map((doc) => doc.name)).toEqual(["Nota", "Transcripción"]);
  });

  test("sin token o base la pantalla dice qué falta y solo los listos figuran vivos", () => {
    const created = makeConnector("notion", "n", "Notion");
    expect(connectorProblem(created.account, created.destination)).toBe("Pega el token de tu integración de Notion.");
    const account = { ...created.account, hasCredential: true };
    expect(connectorProblem(account, created.destination)).toBe("Elige la base donde guardar.");
    const chosen = { ...created.destination, configuration: chooseNotionSource(created.destination.configuration, source) };
    expect(connectorProblem(account, chosen)).toBeNull();
    expect(connectorSubtitle(chosen, null)).toBe("Diario › Notas");
    expect(connectorSubtitle(created.destination, null)).toBe("Sin base elegida");
  });

  test("elegir otra base no arrastra las columnas y refrescar la misma conserva lo escrito", () => {
    const first = chooseNotionSource(makeConnector("notion", "n", "Notion").destination.configuration, source);
    expect(first.columns).toMatchObject({ Nombre: "{{titulo}}", Clave: "{{clave}}" });
    const edited = { ...first, columns: { ...first.columns, Nombre: "Nota: {{titulo}}", Fecha: "" } };
    const refreshed = chooseNotionSource(edited, { ...source, properties: [{ name: "Nombre", type: "title" }] });
    expect(refreshed.columns).toEqual({ Nombre: "Nota: {{titulo}}" });
    const other = chooseNotionSource(edited, { id: "ds-2", title: "Llamadas", databaseTitle: "Llamadas", properties: [{ name: "Asunto", type: "title" }] });
    expect(other.columns).toEqual({ Asunto: "{{titulo}}" });
    expect(other.body).toBe(edited.body);
    expect(writableColumns(source).map((column) => column.name)).toEqual(["Nombre", "Fecha", "Clave"]);
  });

  test("una configuración antigua conserva el mapeo y el cuerpo al abrir el editor", () => {
    const legacy = {
      source: { id: "ds-vieja", title: "Notas", databaseTitle: "Notas", properties: [{ name: "Nombre", type: "title" }, { name: "Fecha", type: "date" }] },
      mapping: { byField: { title: "Nombre", date: "Fecha" } },
      template: { blocks: [{ heading: { _0: "Acta" } }, { transcript: { _0: "timestamps" } }] },
    };
    const restored = notionConfiguration(legacy);
    expect(restored.columns).toEqual({ Nombre: "{{titulo}}", Fecha: "{{fecha-iso}}" });
    expect(restored.body).toBe("# Acta\n\n{{transcripcion-tiempos}}");
    expect(notionConfiguration(restored)).toEqual(restored);
  });

  test("el borrador sin base conserva lo escrito aunque aún no valide para publicar", () => {
    expect(notionConfiguration({ columns: { Nombre: "Mi título" }, body: "# Nota propia" })).toEqual({
      source: { id: "", title: "", databaseTitle: "", properties: [] },
      columns: { Nombre: "Mi título" },
      body: "# Nota propia",
    });
  });

  test("OKF señala primero la carpeta, luego documentos, type y rutas repetidas", () => {
    const config = makeConnector("okf", "o", "OKF").destination.configuration;
    expect(okfProblem(config)).toBe("Elige la carpeta donde guardar las notas.");
    expect(okfProblem({ ...config, folder: "/bundle", documents: [] })).toBe("Añade al menos un documento.");
    const docs = config.documents ?? [];
    expect(okfProblem({ ...config, folder: "/bundle", documents: docs.map((doc, i) => i ? { ...doc, path: docs[0].path } : doc) })).toBe("«Nota» y «Transcripción» escriben en la misma ruta.");
    expect(okfProblem({ ...config, folder: "/bundle", documents: [{ ...docs[0], properties: [{ key: "type", value: " " }] }] })).toBe("«Nota» necesita un valor en type: OKF lo exige.");
    expect(okfProblem({ ...config, folder: "/bundle" })).toBeNull();
    expect(connectorSubtitle({ ...makeConnector("okf", "o", "OKF").destination, configuration: config }, "/Users/ana")).toBe("Sin carpeta elegida");
  });

  test("un documento nuevo lleva ruta y propiedades de serie; la primera propiedad type no se quita", () => {
    const doc = newOKFDocument(3, "doc-3");
    expect(doc).toMatchObject({ name: "Documento 3", path: "documentos/{{dia}}-{{titulo}}.md", body: "{{resumen}}" });
    expect(doc.properties).toEqual([{ key: "type", value: "Documento" }, { key: "title", value: "{{titulo}}" }]);
    expect(removeOKFProperty(doc, 0).properties).toEqual(doc.properties);
    expect(removeOKFProperty(doc, 1).properties).toEqual([{ key: "type", value: "Documento" }]);
  });
});
