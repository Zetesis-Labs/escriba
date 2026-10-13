import { describe, expect, test } from "vitest";
import {
  device,
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
