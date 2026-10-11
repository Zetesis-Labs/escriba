import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vitest";
import { TraceDetail, traceHeadline, traceOutcome, traceText } from "../../src/library/TraceCard";
import type { RecipeTrace } from "../../src/types";

const trace = (error: string, errorCode?: string): RecipeTrace => ({
  id: "t",
  recordingId: "r",
  dryRun: false,
  startedAt: "2026-10-10T00:00:00Z",
  finishedAt: "2026-10-10T00:00:01Z",
  steps: [],
  error,
  ...(errorCode === undefined ? {} : { errorCode }),
});

test("la traza nueva usa el código y la antigua conserva su estado visible", () => {
  expect(traceOutcome(trace("BACKEND_UNAVAILABLE: texto ajeno", "failed"))).toBe("failed");
  expect(traceOutcome(trace("Sin conexión", "backend_unavailable"))).toBe("waiting");
  expect(traceOutcome(trace("BACKEND_UNAVAILABLE: sin conexión"))).toBe("waiting");
});

test("el texto copiado conserva pasos, errores y resultado registrado", () => {
  const execution: RecipeTrace = {
    ...trace("Falló la publicación", "failed"),
    recipeId: "diario",
    dryRun: true,
    steps: [
      { capability: "transcribe", origin: "diario", seconds: 1.25 },
      { capability: "publish", origin: "diario", seconds: 0.4, error: "Sin permiso" },
    ],
    result: { transcript: { text: "Prueba sintética" }, digest: null, data: { etiquetas: ["idea"] } },
  };
  const copied = traceText(execution, "Diario");
  expect(traceHeadline(execution, "Diario")).toContain("Diario");
  expect(copied).toContain("Transcribir · diario · 1,3 s");
  expect(copied).toContain("Publicar · diario · 0,4 s");
  expect(copied).toContain("Sin permiso");
  expect(copied).toContain('"etiquetas": [');
  expect(copied).toContain("Prueba sintética");
  expect(copied).toContain("Prueba de receta");
});

test("el detalle muestra el fallo y el resultado existente sin atribuir salidas a cada paso", () => {
  const execution: RecipeTrace = {
    ...trace("Publicación denegada", "failed"),
    steps: [{ capability: "publish", origin: "diario", seconds: 0.4, error: "Sin permiso" }],
    result: { transcript: { text: "Texto sintético" }, digest: null, data: null },
  };
  const markup = renderToStaticMarkup(createElement(TraceDetail, { trace: execution, recipeName: "Diario" }));
  expect(markup).toContain("Publicar");
  expect(markup).toContain("Falló");
  expect(markup).toContain("Sin permiso");
  expect(markup).toContain("Publicación denegada");
  expect(markup).toContain("Resultado registrado");
  expect(markup).toContain("Transcripción");
  expect(markup).toContain("Texto sintético");
  expect(markup).not.toContain("Resumen · Datos");
});
