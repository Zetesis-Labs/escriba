import { expect, test } from "vitest";
import { okfPublicationFile } from "../../src/core/publicationFiles";

test("la publicación OKF usa el fichero real sin repetir la carpeta del recibo", () => {
  expect(okfPublicationFile("/bundle", { folder: "/bundle", locator: "notas/reunion.md" })).toBe("/bundle/notas/reunion.md");
});

test("una publicación importada de Swift conserva su URL de fichero y decodifica espacios", () => {
  expect(okfPublicationFile("/bundle", { url: "file:///bundle/notas/una%20nota.md", locator: "antiguo" })).toBe("/bundle/notas/una nota.md");
  expect(okfPublicationFile("/bundle", { locator: "/bundle/notas/reunion.md" })).toBe("/bundle/notas/reunion.md");
  expect(okfPublicationFile(undefined, { locator: "nota.md" })).toBeNull();
});
