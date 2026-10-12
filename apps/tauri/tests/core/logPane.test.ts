import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { LogPane } from "../../src/log/LogPane";

test("el Registro solo muestra el log de la app; las ejecuciones están en Trabajos", () => {
  const html = renderToStaticMarkup(createElement(LogPane));
  expect(html).not.toContain("Ejecuciones de recetas");
  expect(html).toContain("Solo errores");
});
