import { describe, expect, test } from "vitest";
import { criteriaLabel, currentVersion, currentVersionLabel, isPublished, liveDestinations, originName, publishedNames, versionTitle } from "../../src/library/model";
import type { Recording, Version } from "../../src/types";

const version = (id: string, createdAt: string, extra: Partial<Version> = {}): Version => ({
  id,
  createdAt,
  backend: "local-stt",
  transcript: { text: "", segments: [] },
  ...extra,
});
const recording = (extra: Partial<Recording> = {}): Recording => ({
  id: "r",
  title: "20261009 161105",
  createdAt: "2026-10-09T14:11:05Z",
  source: "/Users/r/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261009 161105.m4a",
  audioPath: "/audio/r.m4a",
  duration: 12,
  status: "done",
  versions: [],
  publications: [],
  ...extra,
});

describe("la biblioteca de Tauri contada como en Swift", () => {
  test("la versión vigente es la marcada y, si no hay marca, la última en crearse", () => {
    const a = version("a", "2026-10-09T10:00:00Z");
    const b = version("b", "2026-10-09T11:00:00Z");
    expect(currentVersion(recording({ versions: [b, a] }))?.id).toBe("b");
    expect(currentVersion(recording({ versions: [b, a], currentVersionId: "a" }))?.id).toBe("a");
    expect(currentVersionLabel(recording({ versions: [b, a], currentVersionId: "a" }))).toBe("v1 de 2");
    expect(currentVersionLabel(recording())).toBe("Versiones");
  });
  test("el origen es la carpeta vigilada más concreta, y lo añadido o grabado en la app es la Bandeja", () => {
    const folders = [
      { id: "1", path: "/Users/r/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", name: "Recordings", style: "voiceMemos" as const, enabled: true },
      { id: "2", path: "/Users/r/Library", name: "Biblioteca", enabled: true },
    ];
    expect(originName(recording(), folders)).toBe("Notas de Voz");
    expect(originName(recording({ source: "/Users/r/Library/Application Support/dev.zetesis.escriba.tauri/captures/x.m4a" }), folders)).toBe("Library");
    expect(originName(recording({ source: "/Users/r/Desktop/x.m4a" }), folders)).toBe("Bandeja");
  });
  test("los criterios se describen igual que en Swift", () => {
    expect(criteriaLabel(undefined)).toBe("criterios desconocidos");
    expect(criteriaLabel({ language: "es", diarize: false })).toBe("ES · sin hablantes");
    expect(criteriaLabel({ language: null, diarize: true, speakers: null })).toBe("idioma automático · hablantes automáticos");
    expect(criteriaLabel({ language: "auto", diarize: true, speakers: 3 })).toBe("idioma automático · 3 hablantes");
  });
  test("el título de una versión lleva número, receta, criterios, motor y fecha", () => {
    const titulo = versionTitle(
      version("a", "2026-10-09T14:12:05Z", { recipeId: "default", inputs: { language: "es", diarize: false } }),
      1,
      [{ id: "default", name: "Por defecto", kind: "form", values: {} }],
      [{ id: "local-stt", name: "Whisper", role: "stt", local: true, enabled: true }],
    );
    expect(titulo.startsWith("v1 · Por defecto · ES · sin hablantes · Whisper · ")).toBe(true);
  });
  test("una publicación cuenta si tiene recibo y no tiene error", () => {
    const base = { destinationId: "d", name: "Notion", provider: "notion", configuration: {}, updatedAt: "" };
    expect(isPublished({ ...base, receipt: { url: "https://notion.so/x" } })).toBe(true);
    expect(isPublished({ ...base, receipt: {} })).toBe(false);
    expect(isPublished({ ...base, receipt: { url: "x" }, error: "401" })).toBe(false);
    expect(publishedNames(recording({ publications: [{ ...base, receipt: { url: "x" } }] }))).toEqual(["Notion"]);
    const importada = { ...base, name: "03823BB9-D0D1", destinationId: "03823BB9-D0D1", receipt: { url: "x" } };
    expect(publishedNames(recording({ publications: [importada] }), [{ id: "03823BB9-D0D1", name: "Voice Inbox", provider: "notion", account: "n", enabled: true, configuration: {} }])).toEqual(["Voice Inbox"]);
    expect(publishedNames(recording({ publications: [importada] }))).toEqual(["Notion"]);
  });
  test("solo publican los destinos activos de una cuenta activa", () => {
    const destinations = [
      { id: "a", name: "Notion", provider: "notion" as const, account: "n", enabled: true, configuration: {} },
      { id: "b", name: "OKF", provider: "okf" as const, account: "o", enabled: true, configuration: {} },
      { id: "c", name: "Apagado", provider: "okf" as const, account: "o", enabled: false, configuration: {} },
    ];
    const accounts = [
      { id: "n", name: "Notion", provider: "notion" as const, enabled: false },
      { id: "o", name: "OKF", provider: "okf" as const, enabled: true },
    ];
    expect(liveDestinations(destinations, accounts).map((item) => item.id)).toEqual(["b"]);
  });
});
