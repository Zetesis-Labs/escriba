import { describe, expect, it } from "vitest";
import { abbreviatedPath, jobHistoryChoice, jobHistoryDays, jobHistoryOptions } from "../../src/core/settings";

describe("ajustes", () => {
  it("las rutas de la carpeta personal se abrevian con ~ como en el Finder", () => {
    expect(abbreviatedPath("/Users/ana/Library/Group Containers/x/Recordings", "/Users/ana")).toBe("~/Library/Group Containers/x/Recordings");
    expect(abbreviatedPath("/Users/ana", "/Users/ana/")).toBe("~");
    expect(abbreviatedPath("/Users/anabel/Notas", "/Users/ana")).toBe("/Users/anabel/Notas");
    expect(abbreviatedPath("/Volumes/Disco/Notas", null)).toBe("/Volumes/Disco/Notas");
  });

  it("el historial de trabajos se guarda 7 días salvo que se elija 30, 90 o siempre", () => {
    expect(jobHistoryOptions.map((option) => option.label)).toEqual(["7 días", "30 días", "90 días", "Siempre"]);
    expect(jobHistoryChoice({})).toBe("7");
    expect(jobHistoryChoice({ jobHistoryDays: 30 })).toBe("30");
    expect(jobHistoryChoice({ jobHistoryDays: null })).toBe("always");
    expect(jobHistoryDays("90")).toBe(90);
    expect(jobHistoryDays("always")).toBeNull();
  });
});
