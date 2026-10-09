import { describe, expect, it } from "vitest";
import { abbreviatedPath, importReport } from "../../src/core/settings";

describe("ajustes", () => {
  it("las rutas de la carpeta personal se abrevian con ~ como en el Finder", () => {
    expect(abbreviatedPath("/Users/ana/Library/Group Containers/x/Recordings", "/Users/ana")).toBe("~/Library/Group Containers/x/Recordings");
    expect(abbreviatedPath("/Users/ana", "/Users/ana/")).toBe("~");
    expect(abbreviatedPath("/Users/anabel/Notas", "/Users/ana")).toBe("/Users/anabel/Notas");
    expect(abbreviatedPath("/Volumes/Disco/Notas", null)).toBe("/Volumes/Disco/Notas");
  });

  it("el resultado de importar dice cuántas notas llegan y cuántas sin audio", () => {
    expect(importReport({ recordings: 12, audioMissing: 0 })).toBe("12 notas importadas.");
    expect(importReport({ recordings: 1, audioMissing: 1 })).toBe("1 nota importada. 1 sin audio.");
    expect(importReport({ recordings: 30, audioMissing: 4 })).toBe("30 notas importadas. 4 sin audio.");
  });
});
