import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { TranscriptEditor } from "../../src/library/TranscriptEditor";

test("un hablante consecutivo aparece como un bloque sin perder índices de selección", () => {
  const markup = renderToStaticMarkup(createElement(TranscriptEditor, {
    transcript: { text: "Uno. Dos. Tres.", segments: [
      { start: 0, end: 1, text: "Uno.", speaker: "Ana" },
      { start: 1, end: 2, text: "Dos.", speaker: "Ana" },
      { start: 2, end: 3, text: "Tres.", speaker: "Luis" },
    ] },
    editing: false, disabled: false, position: null, speakerColors: { Ana: "#123456" },
    onSeek: () => undefined, onText: () => undefined, onAssign: () => undefined, onError: () => undefined,
  }));
  expect(markup.match(/class="speaker-button"/g)).toHaveLength(2);
  expect(markup).toContain('data-transcript-segment="0"');
  expect(markup).toContain('data-transcript-segment="1"');
  expect(markup).toContain('data-transcript-segment="2"');
  expect(markup).toContain("--speaker-color:#123456");
});
