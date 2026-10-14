import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { PlatformContext } from "../../src/app/platform";
import { macOS } from "../../src/core/platform";
import { RecordingPanel } from "../../src/recording/RecordingPanel";
import { linux } from "./platforms";

const render = (platform = macOS) => renderToStaticMarkup(createElement(PlatformContext.Provider, { value: platform }, createElement(RecordingPanel)));

test("en Linux el panel de grabación lleva su propio fondo; en el Mac, el cristal del sistema", () => {
  expect(render(linux)).toContain('class="recording-hud painted"');
  expect(render()).toContain('class="recording-hud"');
});

test("dentro de la ventana el panel no arrastra la ventana entera", () => {
  const html = renderToStaticMarkup(
    createElement(PlatformContext.Provider, { value: linux }, createElement(RecordingPanel, { docked: true })),
  );
  expect(html).toContain("recording-hud painted");
  expect(html).not.toContain("data-tauri-drag-region");
});
