import { expect, test } from "vitest";
import { traceOutcome } from "../../src/library/TraceCard";
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
