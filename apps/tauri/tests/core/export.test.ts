import { expect, test } from "vitest";
import { transcriptExportJSON } from "../../src/core/export";

test("el JSON copiado tiene la misma forma que el de la app Swift", () => {
  const json = transcriptExportJSON({
    key: "544766795",
    startedAt: new Date("2026-10-09T14:11:05.000Z"),
    source: "/Notas de voz/x.m4a",
    backend: "local-stt",
    transcript: {
      text: "",
      segments: [
        { start: 0, end: 1.5, speaker: "Ana", text: "Hola, mundo", words: [{ start: 0, end: 0.5, text: "Hola," }, { start: 0.9, end: 1.5, text: "mundo" }] },
        { start: 2, end: 3, speaker: "Luis", text: "Bien." },
      ],
    },
  });
  expect(json).toBe(
    [
      "{",
      '  "version": 1,',
      '  "key": "544766795",',
      '  "startedAt": "2026-10-09T14:11:05Z",',
      '  "source": "/Notas de voz/x.m4a",',
      '  "backend": "local-stt",',
      '  "duration": 3,',
      '  "speakers": ["Ana", "Luis"],',
      '  "text": "Hola, mundo\\nBien.",',
      '  "wordFormat": ["start", "end", "text"],',
      '  "segments": [',
      '    {"start": 0, "end": 1.5, "speaker": "Ana", "text": "Hola, mundo", "words": [[0, 0.5, "Hola,"], [0.9, 1.5, "mundo"]]},',
      '    {"start": 2, "end": 3, "speaker": "Luis", "text": "Bien."}',
      "  ]",
      "}",
    ].join("\n"),
  );
});
