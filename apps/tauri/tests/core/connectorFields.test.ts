import { describe, expect, test } from "vitest";
import { accessChanged, availableProviders, connectorDraftDirty, editorRequest, fieldValue, isSafeFieldPath, needsScopeAuthorization, providerAccess, reconcileConnectorDraft, scopeAuthorizationKey, setFieldValue, visibleValidationProblem } from "../../src/core/connectorFields";
import type { Provider } from "@escriba/conectores";
import { isAppConnector, nextConnectorName } from "../../src/core/connectors";
import { connectorEditorResult } from "../../src/runtime/connectorView";

const remote: Provider = {
  id: "example", name: "Ejemplo", capability: "http", origin: "https://example.test",
  allowedHeaders: ["accept"], defaultConfiguration: { documents: [{ title: "Uno" }] },
  credential: { label: "Token", header: "authorization", prefix: "Bearer " },
};

describe("campos de un proveedor instalado", () => {
  test("el proveedor instalado aparece junto a los integrados y sus valores anidados conservan el resto del borrador", () => {
    expect(availableProviders([remote]).map((provider) => provider.id)).toContain("example");
    const edited = setFieldValue(remote.defaultConfiguration, ["documents", 0, "title"], "Dos");
    expect(fieldValue(edited, ["documents", 0, "title"])).toBe("Dos");
    expect(fieldValue(remote.defaultConfiguration, ["documents", 0, "title"])).toBe("Uno");
    expect(setFieldValue(edited, ["flags", "enabled"], true)).toEqual({
      documents: [{ title: "Dos" }], flags: { enabled: true },
    });
  });

  test("una credencial existente requiere reconexión cuando cambia el origen", () => {
    const granted = providerAccess(remote);
    expect(accessChanged(granted, granted)).toBe(false);
    expect(accessChanged(granted, { ...granted, origin: "https://other.test" })).toBe(true);
  });

  test("la petición al programa contiene la cuenta y el borrador, nunca el secreto", () => {
    const account = { id: "cuenta-1", name: "Ejemplo", provider: "example", enabled: true, hasCredential: true, token: "secreto" };
    const request = editorRequest("example", account, { query: "pendiente" }, {});
    expect(request).toEqual({ providerId: "example", accountId: "cuenta-1", configuration: { query: "pendiente" }, state: {} });
    expect(JSON.stringify(request)).not.toContain("secreto");
  });

  test("un refresh conserva los campos en edición y actualiza los no tocados", () => {
    const previous = { name: "Cuenta", enabled: false, configuration: { project: "viejo", folder: "/original" } };
    const draft = { name: "Mi cuenta", enabled: false, configuration: { project: "borrador", folder: "/original" } };
    const saved = { name: "Cuenta externa", enabled: true, configuration: { project: "remoto", folder: "/nuevo" } };
    expect(reconcileConnectorDraft(previous, draft, saved)).toEqual({
      name: "Mi cuenta", enabled: true, configuration: { project: "borrador", folder: "/original" },
    });
  });

  test("una ruta declarada por el proveedor no puede modificar prototipos", () => {
    for (const path of [["__proto__", "polluted"], ["constructor", "prototype"], ["items", 100_000]]) {
      expect(isSafeFieldPath(path)).toBe(false);
      expect(() => setFieldValue({}, path, "sí")).toThrow("Ruta de campo no válida");
    }
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });

  test("la frontera del runtime y el editor comparten el límite de índices", () => {
    const result = (index: number) => ({ view: { sections: [{ fields: [{ type: "text", path: ["items", index], label: "Elemento" }] }] } });
    expect(isSafeFieldPath(["items", 9999])).toBe(true);
    expect(connectorEditorResult(result(9999)).view?.sections[0].fields).toHaveLength(1);
    expect(isSafeFieldPath(["items", 10000])).toBe(false);
    expect(() => connectorEditorResult(result(10000))).toThrow("formulario inválido");
  });

  test("la lista distingue un conector gestionado de un destino de receta con programa", () => {
    const destination = { id: "cuenta-1", name: "Tablero", provider: "example", account: "cuenta-1", enabled: true, configuration: {}, program: "bundle" };
    expect(isAppConnector({ ...destination, managed: true })).toBe(true);
    expect(isAppConnector(destination)).toBe(false);
  });

  test("varias cuentas de cualquier proveedor reciben nombres distintos", () => {
    expect(nextConnectorName("Ejemplo", ["Ejemplo", "Ejemplo 2"])).toBe("Ejemplo 3");
    expect(nextConnectorName("Otro", ["Ejemplo"])).toBe("Otro");
  });

  test("la validación fallida al conectar sigue visible tras refrescar mientras la configuración no cambie", () => {
    const issue = { configuration: JSON.stringify({ project: "" }), message: "Elige un proyecto." };
    expect(visibleValidationProblem(issue, { project: "" })).toBe("Elige un proyecto.");
    expect(visibleValidationProblem(issue, { project: "nuevo" })).toBeNull();
  });

  test("un proveedor sin credencial exige autorización explícita al cambiar origen o carpeta", () => {
    const provider = { ...remote, credential: undefined };
    const account = { id: "cuenta-1", name: "Ejemplo", provider: provider.id, enabled: false };
    expect(needsScopeAuthorization(provider, account, {})).toBe(true);
    const granted = { ...account, grant: providerAccess(provider) };
    expect(needsScopeAuthorization(provider, granted, {})).toBe(false);
    const changed = { ...provider, origin: "https://nuevo.test" };
    expect(needsScopeAuthorization(changed, granted, {})).toBe(true);
    expect(scopeAuthorizationKey(changed, {})).not.toBe(scopeAuthorizationKey(provider, {}));

    const folder = { id: "files", name: "Archivos", capability: "folder" as const, allowedHeaders: [], defaultConfiguration: { folder: "/nuevo" } };
    const folderAccount = { id: "f", name: "Archivos", provider: "files", enabled: true, folder: "/viejo", grant: providerAccess(folder) };
    expect(needsScopeAuthorization(folder, folderAccount, { folder: "/nuevo" })).toBe(true);
  });

  test("autorizar un alcance nuevo permite guardar una cuenta sin activar publicación", () => {
    const draft = { name: "API", enabled: false, configuration: {} };
    expect(connectorDraftDirty(draft, draft, "", false)).toBe(false);
    expect(connectorDraftDirty(draft, draft, "", true)).toBe(true);
  });
});
