import { describe, expect, test } from "vitest";
import {
  device,
  whisperDownloadLabel,
  floatingRecordingPanel,
  paintsPanelBackground,
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
import { linux } from "./platforms";

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
    const flatpak = { ...linux, folderAuthorization: true };
    expect(foldersFooter(flatpak)).toContain("vuelve a autorizarla");
    expect(foldersFooter(flatpak)).not.toMatch(/macOS|disco/i);
  });

  test("sin catálogo de modelos, solo el Mac sabe el tamaño de su Whisper", () => {
    expect(whisperDownloadLabel(macOS)).toBe("Descargar (unos 3 GB)");
    expect(whisperDownloadLabel(linux)).toBe("Descargar");
  });

  test("las opciones salen de lo que Rust dice que ofrece el sistema, no de su nombre", () => {
    const everything: Platform = { ...linux, voiceMemos: true, folderAuthorization: true, systemSettings: true, menuBar: true, floatingPanel: true, drawsWindowControls: false };
    expect(offersVoiceMemos(everything)).toBe(true);
    expect(offersFolderAuthorization(everything)).toBe(true);
    expect(offersSystemSettings(everything)).toBe(true);
    expect(drawsWindowControls(everything)).toBe(false);
    expect(floatingRecordingPanel(everything)).toBe(true);
    expect(paintsPanelBackground(everything)).toBe(false);
    expect(isNewRecordingShortcut({ key: "n", ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }, everything)).toBe(false);
    expect(resolversFooter("llm", { ...linux, bundledLlm: true })).toContain("La que no elige usa");
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
    expect(unisolatedRecipesWarning({ ...linux, recipesIsolated: true })).toBeNull();
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
  test("en Linux el panel va dentro de la ventana; en el Mac flota sobre todo", () => {
    expect(floatingRecordingPanel(macOS)).toBe(true);
    expect(floatingRecordingPanel(linux)).toBe(false);
  });

  test("sin el efecto de cristal del Mac, el panel pinta su propio fondo", () => {
    expect(paintsPanelBackground(linux)).toBe(true);
    expect(paintsPanelBackground(macOS)).toBe(false);
  });
});
