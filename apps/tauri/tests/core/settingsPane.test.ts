import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { snapshot as demoSnapshot } from "../runtime/fixture";
import { SettingsPane } from "../../src/settings/SettingsPane";
import type { Snapshot } from "../../src/types";
import { PlatformContext } from "../../src/app/platform";
import { linux } from "./platforms";

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

function renderOnLinux(watchIssues: Snapshot["watchIssues"] = []) {
  const pane = createElement(SettingsPane, {
    data: {
      ...demoSnapshot,
      settings: {
        ...demoSnapshot.settings,
        watchedFolders: [{ id: "grabaciones", name: "Grabaciones", path: "/carpeta-sintetica", style: "any", enabled: true, authorizationSaved: false }],
      },
      watchIssues,
    },
    refresh: async () => {},
  });
  return renderToStaticMarkup(createElement(PlatformContext.Provider, { value: linux }, pane));
}

test("en Linux Ajustes no ofrece Notas de Voz, autorizar ni acceso total al disco", () => {
  const html = renderOnLinux();
  expect(html).toContain("Añadir carpeta…");
  expect(html).not.toContain("Notas de Voz");
  expect(html).not.toContain("Acceso total al disco");
  expect(html).not.toContain("macOS");
});

test("en Linux una carpeta ilegible muestra el motivo y no pide autorizar", () => {
  const html = renderOnLinux([{ folderId: "grabaciones", path: "/carpeta-sintetica", message: "Permission denied (os error 13)", permissionDenied: true }]);
  expect(html).toContain("No se puede leer esta carpeta: Permission denied (os error 13)");
  expect(html).not.toContain("utorizar");
});
