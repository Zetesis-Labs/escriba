import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { demoSnapshot } from "../../src/app/demo";
import { SettingsPane } from "../../src/settings/SettingsPane";
import type { Snapshot } from "../../src/types";

function renderFolder(authorizationSaved: boolean, watchIssues: Snapshot["watchIssues"] = []) {
  return renderToStaticMarkup(createElement(SettingsPane, {
    data: {
      ...demoSnapshot,
      settings: {
        ...demoSnapshot.settings,
        watchedFolders: [{
          id: "voice-memos", name: "Notas de Voz", path: "/carpeta-sintetica",
          style: "voiceMemos", enabled: true, authorizationSaved,
        }],
      },
      watchIssues,
    },
    refresh: async () => {},
  }));
}

test("una carpeta legible no pide autorizar aunque el acceso venga de macOS y no de un bookmark", () => {
  expect(renderFolder(false)).not.toContain("Autorizar…");
  expect(renderFolder(true)).not.toContain("Volver a autorizar…");
});

test.each([true, false])("un fallo de lectura o de restauración del bookmark permite recuperar el acceso (permissionDenied=%s)", (permissionDenied) => {
  const issues = [{ folderId: "voice-memos", path: "/carpeta-sintetica", message: "No se pudo acceder a la carpeta", permissionDenied }];
  expect(renderFolder(false, issues)).toContain("Autorizar…");
  expect(renderFolder(true, issues)).toContain("Volver a autorizar…");
});

test("el fallo de otra carpeta no pide autorizar una carpeta legible", () => {
  const issues = [{ folderId: "otra-carpeta", path: "/otra-carpeta", message: "Acceso denegado", permissionDenied: true }];
  expect(renderFolder(false, issues)).not.toContain("Autorizar…");
  expect(renderFolder(true, issues)).not.toContain("Volver a autorizar…");
});
