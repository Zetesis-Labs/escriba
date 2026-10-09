import { describe, expect, test } from "vitest";
import { importNotice, importPlan, relabelled } from "../../src/core/inbox";

describe("añadir audios a la biblioteca", () => {
  test("solo entran los audios que Escriba sabe leer", () => {
    expect(importPlan(["/a/nota.M4A", "/a/foto.png", "/a/sin"])).toEqual({ accepted: ["/a/nota.M4A"], rejected: ["foto.png", "sin"] });
  });
  test("el aviso cuenta lo añadido, lo rechazado y lo que falló con los textos de Swift", () => {
    expect(importNotice({ added: ["nota.m4a"], rejected: [], failed: [] })).toBe("«nota.m4a» añadida; se transcribe enseguida.");
    expect(importNotice({ added: ["a", "b"], rejected: ["c.png"], failed: ["d.m4a", "e.m4a"] })).toBe(
      "2 grabaciones añadidas; se transcriben enseguida. «c.png» no es un audio que Escriba sepa leer. No se pudieron copiar 2 ficheros.",
    );
    expect(importNotice({ added: [], rejected: [], failed: [] })).toBeNull();
  });
});

describe("corregir hablantes", () => {
  test("renombrar o fusionar cambia la etiqueta de sus segmentos y deja el resto", () => {
    const transcript = {
      text: "",
      segments: [
        { start: 0, end: 1, speaker: "Speaker 1", text: "a" },
        { start: 1, end: 2, speaker: "Speaker 2", text: "b" },
        { start: 2, end: 3, speaker: null, text: "c" },
      ],
    };
    expect(relabelled(transcript, ["Speaker 1"], "Ana").segments.map((segment) => segment.speaker)).toEqual(["Ana", "Speaker 2", null]);
  });
});
