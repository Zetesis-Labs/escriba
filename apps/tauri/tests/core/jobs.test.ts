import { describe, expect, it } from "vitest";
import { activeOrder, appendPage, historyKinds, historyQuery, jobActions, jobAttempts, jobKind, jobStatus, jobTimes, refreshedHistory, runningCount } from "../../src/core/jobs";
import type { Job } from "../../src/generated/Job";

const madrid = "Europe/Madrid";
const at = (text: string) => new Date(`${text}:00+02:00`).getTime();
const now = new Date(at("2026-10-12 10:45"));

function job(id: string, fields: Partial<Job> = {}): Job {
  return {
    id,
    recordingId: `nota-${id}`,
    operation: "processRecording",
    args: { recordingId: `nota-${id}` },
    automatic: false,
    audioHash: null,
    recipe: { id: "resumen", name: "Resumen" },
    state: "queued",
    stage: "En cola",
    attempt: 0,
    createdAt: at("2026-10-12 10:00"),
    startedAt: at("2026-10-12 10:00"),
    finishedAt: null,
    nextAttemptAt: 0,
    error: null,
    errorCode: null,
    result: null,
    ...fields,
  };
}

describe("trabajos en marcha", () => {
  it("ordena primero los que corren, luego la cola por llegada y al final los reintentos por hora", () => {
    const jobs = [
      job("reintento-tarde", { state: "retry", nextAttemptAt: at("2026-10-12 11:30") }),
      job("cola-segunda", { createdAt: at("2026-10-12 10:20") }),
      job("corre", { state: "running", startedAt: at("2026-10-12 10:42") }),
      job("reintento-pronto", { state: "retry", nextAttemptAt: at("2026-10-12 11:05") }),
      job("cola-primera", { createdAt: at("2026-10-12 10:10") }),
    ];
    expect(activeOrder(jobs).map((item) => item.id)).toEqual(["corre", "cola-primera", "cola-segunda", "reintento-pronto", "reintento-tarde"]);
  });

  it("cuenta solo los que se están ejecutando", () => {
    expect(runningCount([job("a", { state: "running" }), job("b"), job("c", { state: "retry" }), job("d", { state: "running" })])).toBe(2);
    expect(runningCount([job("a")])).toBe(0);
  });

  it("muestra la etapa, desde cuándo y cuánto lleva", () => {
    const running = job("a", { state: "running", stage: "Transcribiendo", startedAt: at("2026-10-12 10:42") });
    expect(jobStatus(running, now, madrid)).toBe("Transcribiendo");
    expect(jobTimes(running, now, madrid)).toBe("desde hoy, 10:42 · 3 min");
    expect(jobStatus(job("b"), now, madrid)).toBe("En cola");
    expect(jobTimes(job("b"), now, madrid)).toBe("desde hoy, 10:00");
    const retry = job("c", { state: "retry", nextAttemptAt: at("2026-10-12 11:05") });
    expect(jobStatus(retry, now, madrid)).toBe("Reintento hoy, 11:05");
    expect(jobTimes(retry, now, madrid)).toBe("");
  });
});

describe("historial de trabajos", () => {
  it("dice cuándo acabó y cuánto duró si llegó a ejecutarse", () => {
    const done = job("a", { state: "succeeded", attempt: 1, startedAt: at("2026-10-12 09:54"), finishedAt: at("2026-10-12 09:58") });
    expect(jobStatus(done, now, madrid)).toBe("Terminado");
    expect(jobTimes(done, now, madrid)).toBe("hoy, 09:58 · 4 min");
    const failed = job("b", { state: "failed", attempt: 1, startedAt: at("2026-10-11 20:00"), finishedAt: at("2026-10-11 20:00") + 12_000 });
    expect(jobStatus(failed, now, madrid)).toBe("Fallido");
    expect(jobTimes(failed, now, madrid)).toBe("ayer, 20:00 · 12 s");
    const long = job("c", { state: "succeeded", attempt: 1, startedAt: at("2026-10-12 07:00"), finishedAt: at("2026-10-12 08:05") });
    expect(jobTimes(long, now, madrid)).toBe("hoy, 08:05 · 1 h 5 min");
    const neverRan = job("d", { state: "cancelled", finishedAt: at("2026-10-12 09:40") });
    expect(jobStatus(neverRan, now, madrid)).toBe("Cancelado");
    expect(jobTimes(neverRan, now, madrid)).toBe("hoy, 09:40");
  });

  it("entiende trabajos guardados antes de que se registrara el final", () => {
    const legacy = job("a", { state: "succeeded", attempt: 1, recipe: null, createdAt: at("2026-10-10 09:00"), startedAt: at("2026-10-10 09:00"), finishedAt: null });
    expect(jobTimes(legacy, now, madrid)).toBe("10 oct, 09:00");
    expect(jobKind(legacy, [])).toBe("Procesar");
  });

  it("nombra la receta o la acción manual con su destino", () => {
    const destinations = [{ id: "notion", name: "Notion" }];
    expect(jobKind(job("a"), destinations)).toBe("Receta Resumen");
    expect(jobKind(job("t", { args: { recordingId: "x", options: { recipeId: "resumen", dryRun: true } } }), destinations)).toBe("Prueba de la receta Resumen");
    expect(jobKind(job("b", { operation: "summarizeRecording", recipe: null }), destinations)).toBe("Resumir a mano");
    expect(jobKind(job("c", { operation: "publishRecording", recipe: null, args: { recordingId: "x", destinationId: "notion" } }), destinations)).toBe("Publicar en Notion");
    expect(jobKind(job("d", { operation: "unpublishRecording", recipe: null, args: { recordingId: "x", destinationId: "notion" } }), destinations)).toBe("Retirar de Notion");
    expect(jobKind(job("e", { operation: "publishRecording", recipe: null, args: { recordingId: "x", destinationId: "borrado" } }), destinations)).toBe("Publicar en un destino borrado");
  });

  it("ofrece cada acción solo donde aplica", () => {
    expect(jobActions(job("a"))).toEqual({ cancel: true, relaunch: false, error: false, steps: false });
    expect(jobActions(job("b", { state: "running", attempt: 1 }))).toEqual({ cancel: true, relaunch: false, error: false, steps: false });
    expect(jobActions(job("c", { state: "retry", attempt: 1, error: "429" }))).toEqual({ cancel: true, relaunch: false, error: false, steps: false });
    expect(jobActions(job("d", { state: "failed", attempt: 1, error: "Resumen vacío" }))).toEqual({ cancel: false, relaunch: true, error: true, steps: true });
    expect(jobActions(job("e", { state: "cancelled", error: "Proceso cancelado" }))).toEqual({ cancel: false, relaunch: true, error: false, steps: false });
    expect(jobActions(job("f", { state: "succeeded", attempt: 2 }))).toEqual({ cancel: false, relaunch: false, error: false, steps: true });
    const published = job("g", { operation: "publishRecording", recipe: null, state: "failed", attempt: 1, error: "403" });
    expect(jobActions(published)).toEqual({ cancel: false, relaunch: true, error: true, steps: false });
  });

  it("filtra por las recetas del historial y por las tres acciones manuales", () => {
    const kinds = historyKinds([{ id: "zeta", name: "Zeta" }, { id: "acta", name: "Acta" }]);
    expect(kinds.map((kind) => kind.label)).toEqual(["Todas", "Receta Acta", "Receta Zeta", "Resumir a mano", "Publicar", "Retirar publicación"]);
    expect(historyQuery("all", "all", null)).toEqual({ limit: 100 });
    const recipe = kinds[1].value;
    expect(historyQuery("failed", recipe, { endedAt: 5, id: "x" })).toEqual({ limit: 100, state: "failed", recipeId: "acta", before: { endedAt: 5, id: "x" } });
    expect(historyQuery("cancelled", kinds[4].value, null)).toEqual({ limit: 100, state: "cancelled", operation: "publishRecording" });
  });

  it("numera los intentos de una ejecución con el último primero", () => {
    const traces = [{ id: "c" }, { id: "b" }, { id: "a" }];
    expect(jobAttempts(traces).map((attempt) => [attempt.label, attempt.trace.id])).toEqual([["Intento 3", "c"], ["Intento 2", "b"], ["Intento 1", "a"]]);
    expect(jobAttempts([{ id: "solo" }]).map((attempt) => attempt.label)).toEqual(["Ejecución"]);
  });

  it("añade la página siguiente sin repetir trabajos", () => {
    expect(appendPage([job("a"), job("b")], [job("b"), job("c")]).map((item) => item.id)).toEqual(["a", "b", "c"]);
  });

  it("al terminar un trabajo renueva la primera página y conserva las más antiguas ya cargadas", () => {
    const done = (id: string, minute: number) => job(id, { state: "succeeded", finishedAt: at("2026-10-12 09:00") + minute * 60_000 });
    const loaded = [done("e", 50), done("d", 40), done("c", 30), done("b", 20), done("a", 10)];
    const olderCursor = { endedAt: at("2026-10-12 09:00") + 10 * 60_000, id: "a" };
    const fresh = { jobs: [done("nuevo", 55), done("e", 50)], recipes: [], next: { endedAt: at("2026-10-12 09:00") + 50 * 60_000, id: "e" } };
    const refreshed = refreshedHistory(loaded, olderCursor, fresh);
    expect(refreshed.rows.map((item) => item.id)).toEqual(["nuevo", "e", "d", "c", "b", "a"]);
    expect(refreshed.next).toEqual(olderCursor);
    const all = refreshedHistory(loaded, null, { jobs: [done("nuevo", 55), done("d", 40)], recipes: [], next: null });
    expect(all).toEqual({ rows: [done("nuevo", 55), done("d", 40)], next: null });
    const firstOnly = refreshedHistory([done("e", 50)], fresh.next, fresh);
    expect(firstOnly).toEqual({ rows: fresh.jobs, next: fresh.next });
  });
});
