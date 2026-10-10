import { expect, test } from "vitest";
import { dirtyProjectDrafts, projectCreateArgs, projectDraft, projectDrafts, projectFileTree, projectFileVisible, projectRevealPath, projectSaveArgs, unsavedProjectFiles, updateProjectDrafts } from "../../src/core/projectDrafts";

test("cambiar entre archivos conserva cada borrador sin escribirlo todavía", () => {
  let drafts = projectDrafts();
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "recetas/uno/receta.ts", source: "uno" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "recetas/uno/receta.ts", source: "uno editado" });
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "fixtures/datos.ts", source: "datos" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "fixtures/datos.ts", source: "datos editados" });

  expect(projectDraft(drafts, "recetas/uno/receta.ts")).toEqual({ source: "uno editado", saved: "uno" });
  expect(projectDraft(drafts, "fixtures/datos.ts")).toEqual({ source: "datos editados", saved: "datos" });
});

test("guardar una versión anterior no borra cambios escritos mientras guardaba", () => {
  let drafts = projectDrafts();
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "recetas/uno/receta.ts", source: "uno" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "recetas/uno/receta.ts", source: "primera edición" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "recetas/uno/receta.ts", source: "segunda edición" });
  drafts = updateProjectDrafts(drafts, { type: "saved", entry: "recetas/uno/receta.ts", source: "primera edición" });

  expect(projectDraft(drafts, "recetas/uno/receta.ts")).toEqual({ source: "segunda edición", saved: "primera edición" });
});

test("el explorador agrupa rutas del proyecto sin repetir carpetas", () => {
  expect(projectFileTree([
    "recetas/uno/receta.ts",
    "conectores.ts",
    "recetas/dos/receta.ts",
    "recetas/uno/datos.ts",
  ])).toEqual([
    { name: "conectores.ts", path: "conectores.ts" },
    { name: "recetas", path: "recetas", children: [
      { name: "dos", path: "recetas/dos", children: [{ name: "receta.ts", path: "recetas/dos/receta.ts" }] },
      { name: "uno", path: "recetas/uno", children: [
        { name: "datos.ts", path: "recetas/uno/datos.ts" },
        { name: "receta.ts", path: "recetas/uno/receta.ts" },
      ] },
    ] },
  ]);
});

test("comprobar o construir espera a que se guarden todos los archivos modificados", () => {
  let drafts = projectDrafts();
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "conectores.ts", source: "original" });
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "recetas/uno/receta.ts", source: "original" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "recetas/uno/receta.ts", source: "nuevo" });
  expect(unsavedProjectFiles(drafts)).toEqual(["recetas/uno/receta.ts"]);
  drafts = updateProjectDrafts(drafts, { type: "saved", entry: "recetas/uno/receta.ts", source: "nuevo" });
  expect(unsavedProjectFiles(drafts)).toEqual([]);
});

test("al volver al editor se recuperan solo los borradores pendientes", () => {
  let drafts = projectDrafts();
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "recetas/una.ts", source: "antes" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "recetas/una.ts", source: "después" });
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "datos.ts", source: "viejos" });
  expect(dirtyProjectDrafts(drafts)).toEqual({ "recetas/una.ts": { source: "después", saved: "antes" } });
});

test("un archivo nuevo debe ser visible en la lista de fuentes", () => {
  expect(projectFileVisible("recetas/nueva/receta.ts")).toBe(true);
  expect(projectFileVisible("fixtures/datos.json")).toBe(true);
  expect(projectFileVisible("recetas/nueva/imagen.png")).toBe(false);
});

test("nombres heredados de Object son archivos independientes", () => {
  let drafts = projectDrafts();
  expect(projectDraft(drafts, "constructor")).toBeUndefined();
  expect(projectDraft(drafts, "__proto__")).toBeUndefined();
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "constructor", source: "uno" });
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "__proto__", source: "dos" });
  expect(projectDraft(drafts, "constructor")).toEqual({ source: "uno", saved: "uno" });
  expect(projectDraft(drafts, "__proto__")).toEqual({ source: "dos", saved: "dos" });
});

test("guardar comprueba la base leída y crear exige que no exista el archivo", () => {
  const draft = { source: "edición", saved: "versión leída" };
  expect(projectSaveArgs("recetas/uno/receta.ts", draft)).toEqual({
    entry: "recetas/uno/receta.ts", source: "edición", expectedSource: "versión leída",
  });
  expect(projectCreateArgs("recetas/nueva/receta.ts")).toEqual({
    entry: "recetas/nueva/receta.ts", source: "", createNew: true,
  });
});

test("Finder usa la fuente declarada y nunca construye una ruta desde el ID", () => {
  expect(projectRevealPath("/proyecto", "src/recetas/ejemplo/receta.ts")).toBe("/proyecto/src/recetas/ejemplo/receta.ts");
  expect(projectRevealPath("/proyecto", undefined)).toBe("/proyecto");
  expect(projectRevealPath("/proyecto", "../fuera/receta.ts")).toBe("/proyecto");
  expect(projectRevealPath("/proyecto", "dist/receta.js")).toBe("/proyecto");
});

test("recargar sustituye el borrador por la fuente nueva solo tras leerla", () => {
  let drafts = projectDrafts();
  drafts = updateProjectDrafts(drafts, { type: "loaded", entry: "recetas/una/receta.ts", source: "fuente anterior" });
  drafts = updateProjectDrafts(drafts, { type: "edited", entry: "recetas/una/receta.ts", source: "cambio pendiente" });
  expect(projectDraft(drafts, "recetas/una/receta.ts")).toEqual({ source: "cambio pendiente", saved: "fuente anterior" });
  drafts = updateProjectDrafts(drafts, { type: "reloaded", entry: "recetas/una/receta.ts", source: "cambio externo" });
  expect(projectDraft(drafts, "recetas/una/receta.ts")).toEqual({ source: "cambio externo", saved: "cambio externo" });
  expect(unsavedProjectFiles(drafts)).toEqual([]);
});
