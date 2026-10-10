import { describe, expect, it } from "vitest";
import { abbreviatedPath } from "../../src/core/settings";

describe("ajustes", () => {
  it("las rutas de la carpeta personal se abrevian con ~ como en el Finder", () => {
    expect(abbreviatedPath("/Users/ana/Library/Group Containers/x/Recordings", "/Users/ana")).toBe("~/Library/Group Containers/x/Recordings");
    expect(abbreviatedPath("/Users/ana", "/Users/ana/")).toBe("~");
    expect(abbreviatedPath("/Users/anabel/Notas", "/Users/ana")).toBe("/Users/anabel/Notas");
    expect(abbreviatedPath("/Volumes/Disco/Notas", null)).toBe("/Volumes/Disco/Notas");
  });
});
