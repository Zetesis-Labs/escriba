import { describe, expect, test } from "vitest";
import {
  templateCatalog, templatePathCatalog, templatePieces, templateSource, templateToken,
  templateTokenLabel, tokenSuggestions, templateSlashQuery, templateNormalizeSource,
  templateSelectedSource, templateReplaceSelection,
} from "../../src/core/templates";

describe("plantilla de texto con datos", () => {
  test("el texto y los datos se separan, y se vuelven a unir igual", () => {
    const fuente = "# Resumen\n\n{{resumen}}\n\nVer {{enlace:doc-2}} · {{transcripcion-tiempos}}";
    const piezas = templatePieces(fuente);
    expect(piezas).toEqual([
      { kind: "text", text: "# Resumen\n\n" },
      { kind: "token", token: { marker: "resumen" } },
      { kind: "text", text: "\n\nVer " },
      { kind: "token", token: { marker: "enlace:doc-2" } },
      { kind: "text", text: " · " },
      { kind: "token", token: { marker: "transcripcion-tiempos" } },
    ]);
    expect(templateSource(piezas)).toBe(fuente);
  });

  test("el menú de barra filtra sin tildes ni mayúsculas", () => {
    expect(tokenSuggestions("tit", "body").map(({ token }) => token.marker)).toEqual(["titulo"]);
    expect(tokenSuggestions("TRANSCRIPCION", "body").map(({ token }) => token.marker)).toEqual([
      "transcripcion", "transcripcion-tiempos", "transcripcion-texto",
    ]);
    expect(tokenSuggestions("", "body")).toHaveLength(16);
    expect(tokenSuggestions("zzz", "body")).toEqual([]);
  });

  test("lo que no es un dato conocido se queda como texto, llaves incluidas", () => {
    expect(templatePieces("{{no-existe}} y {{ titulo }} y {titulo}")).toEqual([{ kind: "text", text: "{{no-existe}} y {{ titulo }} y {titulo}" }]);
    expect(templatePieces("{{titulo")).toEqual([{ kind: "text", text: "{{titulo" }]);
    expect(templatePieces("")).toEqual([]);
  });

  test("cada dato tiene su marca estable para guardarlo", () => {
    for (const token of templateCatalog) expect(templateToken(token.marker)).toEqual(token);
    expect(templateToken("enlace:abc")).toEqual({ marker: "enlace:abc" });
    expect(templateToken("enlace:")).toBeNull();
  });

  test("en la ruta solo se ofrecen datos que sirven para nombrar un fichero", () => {
    expect(tokenSuggestions("", "path").map(({ token }) => token)).toEqual(templatePathCatalog);
  });

  test("los enlaces ofrecen los otros documentos por su nombre, nunca el propio", () => {
    const links = [{ id: "a", name: "Nota" }, { id: "b", name: "Transcripción" }];
    const suggestions = tokenSuggestions("enl", "body", links, "a");
    expect(suggestions.map(({ token }) => token.marker)).toEqual(["enlace:b"]);
    expect(suggestions[0]?.label).toBe("Enlace a «Transcripción»");
    expect(tokenSuggestions("transcripcion", "body", links).map(({ token }) => token.marker)).toContain("enlace:b");
    expect(tokenSuggestions("enl", "body", [{ id: "b", name: "Primero" }, { id: "b", name: "Segundo" }])[0]?.label).toBe("Enlace a «Primero»");
  });

  test("la pastilla de cada dato dice qué es", () => {
    expect(templateTokenLabel({ marker: "titulo" })).toBe("Título");
    expect(templateTokenLabel({ marker: "transcripcion-tiempos" })).toBe("Transcripción con tiempos");
    expect(templateTokenLabel({ marker: "enlace:b" }, { b: "Transcripción" })).toBe("Enlace a «Transcripción»");
    expect(templateTokenLabel({ marker: "enlace:borrado" })).toBe("Enlace a un documento que ya no existe");
    expect(templateTokenLabel({ marker: "enlace:vacio" }, { vacio: "" })).toBe("Enlace a «»");
  });

  test("la barra abre sugerencias solo en los lugares de Swift y limita la consulta a 31 caracteres", () => {
    expect(templateSlashQuery("/tit", "body")).toEqual({ start: 0, query: "tit" });
    expect(templateSlashQuery("hola /tit", "body")).toEqual({ start: 5, query: "tit" });
    expect(templateSlashQuery("{{no importa}}", "body")).toBeNull();
    expect(templateSlashQuery("\uFFFC/tit", "body")).toEqual({ start: 1, query: "tit" });
    expect(templateSlashQuery("(/tit", "body")).toEqual({ start: 1, query: "tit" });
    expect(templateSlashQuery("[/tit", "property")).toEqual({ start: 1, query: "tit" });
    expect(templateSlashQuery("texto/tit", "body")).toBeNull();
    expect(templateSlashQuery("/con espacio", "body")).toBeNull();
    expect(templateSlashQuery(`/${"a".repeat(31)}`, "body")).toEqual({ start: 0, query: "a".repeat(31) });
    expect(templateSlashQuery(`/${"a".repeat(32)}`, "body")).toBeNull();
    expect(templateSlashQuery("carpeta//dia", "path")).toEqual({ start: 8, query: "dia" });
    expect(templateSlashQuery("nota-/dia", "path")).toEqual({ start: 5, query: "dia" });
    expect(templateSlashQuery("nota_/dia", "path")).toEqual({ start: 5, query: "dia" });
    expect(templateSlashQuery("nota(/dia", "path")).toBeNull();
  });

  test("el pegado de una línea convierte CRLF y otros saltos en un espacio", () => {
    expect(templateNormalizeSource("uno\r\ndos\ntres\rcuatro", false)).toBe("uno dos tres cuatro");
    expect(templateNormalizeSource("uno\r\ndos", true)).toBe("uno\ndos");
  });

  test("copiar y cortar una selección entre líneas conserva marcadores y une el texto restante", () => {
    const source = "Antes {{titulo}}\nDespués {{resumen}} final";
    expect(templateSelectedSource(source, 6, 15)).toBe("{{titulo}}\nDespués");
    expect(templateReplaceSelection(source, 6, 15, "", true)).toEqual({ source: "Antes  {{resumen}} final", caret: 6 });
  });

  test("pegar marcadores en varias líneas mantiene las pastillas y la posición del cursor", () => {
    expect(templateReplaceSelection("Hola mundo", 5, 5, "{{titulo}}\r\n{{resumen}}", true))
      .toEqual({ source: "Hola {{titulo}}\n{{resumen}}mundo", caret: 8 });
    expect(templateReplaceSelection("Hola mundo", 5, 5, "{{titulo}}\r\n{{resumen}}", false))
      .toEqual({ source: "Hola {{titulo}} {{resumen}}mundo", caret: 8 });
  });
});
