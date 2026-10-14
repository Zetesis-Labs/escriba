import { describe, expect, test } from "vitest";
import {
  device,
  paintsPanelBackground,
  platformFromQuery,
  drawsWindowControls,
  isNewRecordingShortcut,
  foldersFooter,
  macOS,
  offersFolderAuthorization,
  offersSystemSettings,
  offersVoiceMemos,
  openInFolder,
  platformOf,
  revealInFolder,
  revealShort,
  shortcut,
  unisolatedRecipesWarning,
  type Platform,
} from "../../src/core/platform";
import { localName, resolverSubtitle, resolversFooter, removedResolverNote } from "../../src/core/resolvers";

const linux: Platform = { system: "linux", recipesIsolated: false };
const local = { id: "local-stt", name: "Whisper", role: "stt" as const, local: true, enabled: true };

describe("plataforma", () => {
  test("sin datos de plataforma la interfaz es la del Mac", () => {
    expect(platformOf(null)).toEqual(macOS);
    expect(platformOf({})).toEqual(macOS);
    expect(platformOf({ platform: linux })).toEqual(linux);
  });

  test("en el Mac nada cambia", () => {
    expect(device(macOS)).toBe("Mac");
    expect(offersVoiceMemos(macOS)).toBe(true);
    expect(offersFolderAuthorization(macOS)).toBe(true);
    expect(offersSystemSettings(macOS)).toBe(true);
    expect(revealInFolder(macOS)).toBe("Mostrar en Finder");
    expect(openInFolder(macOS)).toBe("Abrir en el Finder");
    expect(revealShort(macOS)).toBe("Finder");
    expect(shortcut(macOS, "S")).toBe("⌘S");
    expect(foldersFooter(macOS)).toContain("Si macOS impide leer una carpeta");
    expect(unisolatedRecipesWarning(macOS)).toBeNull();
    expect(localName("stt")).toBe("Whisper en este Mac");
    expect(localName("llm")).toBe("Apple Intelligence");
    expect(resolverSubtitle(local, null)).toBe("En este Mac");
  });

  test("en Linux no hay Notas de Voz, autorizaciones ni Ajustes del Sistema", () => {
    expect(device(linux)).toBe("equipo");
    expect(offersVoiceMemos(linux)).toBe(false);
    expect(offersFolderAuthorization(linux)).toBe(false);
    expect(offersSystemSettings(linux)).toBe(false);
    expect(foldersFooter(linux)).not.toMatch(/macOS|autoriz|disco/i);
  });

  test("en Linux se muestra en la carpeta y los atajos usan Ctrl", () => {
    expect(revealInFolder(linux)).toBe("Mostrar en la carpeta");
    expect(openInFolder(linux)).toBe("Mostrar en la carpeta");
    expect(revealShort(linux)).toBe("Carpeta");
    expect(shortcut(linux, "S")).toBe("Ctrl+S");
  });

  test("en Linux el Whisper local es de este equipo y no hay LLM incluido", () => {
    expect(localName("stt", linux)).toBe("Whisper · en este equipo");
    expect(resolverSubtitle(local, null, linux)).toBe("En este equipo");
    expect(resolversFooter("stt", linux)).toBe("Cada receta elige con qué transcribir, en Recetas. La que no elige usa Whisper · en este equipo.");
    expect(resolversFooter("llm", linux)).toBe("Cada receta elige con qué resumir, en Recetas. La que no elige no puede resumir.");
    expect(resolversFooter("llm", macOS)).toBe("Cada receta elige con qué resumir, en Recetas. La que no elige usa Apple Intelligence.");
    expect(removedResolverNote("llm", linux)).toBe("Se borra su clave. Las recetas que lo usaban se quedan sin LLM.");
    expect(removedResolverNote("stt", linux)).toBe("Se borra su clave. Las recetas que lo usaban pasan a Whisper · en este equipo.");
    expect(removedResolverNote("llm", macOS)).toBe("Se borra su clave. Las recetas que lo usaban pasan a Apple Intelligence.");
  });

  test("sin aislamiento de recetas hay un aviso permanente que explica qué falta", () => {
    const warning = unisolatedRecipesWarning(linux);
    expect(warning).toContain("no permite aislar las recetas");
    expect(unisolatedRecipesWarning({ system: "linux", recipesIsolated: true })).toBeNull();
  });
});

describe("ventana integrada", () => {
  const key = (init: Partial<{ key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean; shiftKey: boolean }>) => ({
    key: "n", ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...init,
  });

  test("Linux dibuja sus propios botones de ventana; el Mac usa los del sistema", () => {
    expect(drawsWindowControls(linux)).toBe(true);
    expect(drawsWindowControls(macOS)).toBe(false);
  });

  test("en Linux Ctrl+N es nueva grabación; en el Mac lo hace el menú", () => {
    expect(isNewRecordingShortcut(key({ ctrlKey: true }), linux)).toBe(true);
    expect(isNewRecordingShortcut(key({ key: "N", ctrlKey: true }), linux)).toBe(true);
    expect(isNewRecordingShortcut(key({ ctrlKey: true, shiftKey: true }), linux)).toBe(false);
    expect(isNewRecordingShortcut(key({ ctrlKey: true, altKey: true }), linux)).toBe(false);
    expect(isNewRecordingShortcut(key({}), linux)).toBe(false);
    expect(isNewRecordingShortcut(key({ key: "s", ctrlKey: true }), linux)).toBe(false);
    expect(isNewRecordingShortcut(key({ ctrlKey: true }), macOS)).toBe(false);
    expect(isNewRecordingShortcut(key({ metaKey: true }), macOS)).toBe(false);
  });
});

describe("panel de grabación", () => {
  test("el panel sabe su sistema por la dirección con la que lo abre Rust", () => {
    expect(platformFromQuery("?panel=recording&platform=linux").system).toBe("linux");
    expect(platformFromQuery("?panel=recording")).toEqual(macOS);
    expect(platformFromQuery("?panel=recording&platform=macos")).toEqual(macOS);
  });

  test("sin el efecto de cristal del Mac, el panel pinta su propio fondo", () => {
    expect(paintsPanelBackground(linux)).toBe(true);
    expect(paintsPanelBackground(macOS)).toBe(false);
  });
});
