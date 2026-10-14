import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { Pane } from "../../src/app/Pane";
import { PlatformContext } from "../../src/app/platform";
import { macOS } from "../../src/core/platform";
import { linux } from "./platforms";

const render = (platform = macOS) =>
  renderToStaticMarkup(createElement(PlatformContext.Provider, { value: platform }, createElement(Pane, { title: "Ajustes", children: null })));

test("en Linux la barra del panel lleva minimizar, maximizar y cerrar a la derecha", () => {
  const html = render(linux);
  const labels = [...html.matchAll(/aria-label="([^"]+)"/g)].map((match) => match[1]);
  expect(labels).toEqual(["Minimizar", "Maximizar", "Cerrar"]);
  expect(html.indexOf("pane-toolbar-items")).toBeLessThan(html.indexOf("window-controls"));
});

test("en el Mac los botones de ventana son los del sistema", () => {
  expect(render()).not.toContain("window-controls");
});
