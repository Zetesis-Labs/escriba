import { describe, expect, test } from "vitest";
import {
  clockStamp,
  durationClock,
  librarySummary,
  playbackPosition,
  recordingExcerpt,
  recordingTitle,
  recordingWhen,
  renderedTranscript,
  rowActionText,
  speakerBefore,
  startsNewSpeaker,
  visibleTags,
} from "../../src/core/presentation";
import type { Segment, Transcript } from "../../src/types";

const madrid = "Europe/Madrid";
const fecha = (texto: string) => {
  const [day, time] = texto.split(" ");
  const local = new Date(`${day}T${time}:00Z`);
  const offset = new Date(local.toLocaleString("en-US", { timeZone: madrid })).getTime() - new Date(local.toLocaleString("en-US", { timeZone: "UTC" })).getTime();
  return new Date(local.getTime() - offset);
};
const segment = (speaker: string | null, start: number, text = "…"): Segment => ({ start, end: start + 1, speaker, text });

describe("marca de reloj", () => {
  test("segundos a m:ss con ceros a la izquierda", () => {
    expect(clockStamp(0)).toBe("0:00");
    expect(clockStamp(5)).toBe("0:05");
    expect(clockStamp(65)).toBe("1:05");
    expect(clockStamp(3599)).toBe("59:59");
    expect(clockStamp(3600)).toBe("60:00");
  });
  test("trunca los decimales y no pinta negativos", () => {
    expect(clockStamp(59.9)).toBe("0:59");
    expect(clockStamp(-3)).toBe("0:00");
  });
  test("el reloj de la grabación pasa a horas a partir de una hora", () => {
    expect(durationClock(5)).toBe("00:05");
    expect(durationClock(3599)).toBe("59:59");
    expect(durationClock(3725)).toBe("1:02:05");
  });
});

describe("hablante anterior en la transcripción", () => {
  const segments = [segment("Ana", 0), segment("Ana", 1), segment("Luis", 2), segment(null, 3)];
  test("el primer segmento no tiene anterior", () => {
    expect(speakerBefore(segments, 0)).toBeNull();
    expect(startsNewSpeaker(segments, 0)).toBe(true);
  });
  test("solo cambia de hablante cuando el anterior es distinto", () => {
    expect(startsNewSpeaker(segments, 1)).toBe(false);
    expect(startsNewSpeaker(segments, 2)).toBe(true);
    expect(speakerBefore(segments, 2)).toBe("Ana");
    expect(startsNewSpeaker(segments, 3)).toBe(true);
  });
  test("un índice fuera de rango no revienta", () => {
    expect(speakerBefore(segments, 99)).toBeNull();
    expect(startsNewSpeaker(segments, 99)).toBe(false);
  });
});

describe("cómo se presenta cada grabación en la biblioteca", () => {
  const resumen = { title: "Prueba numérica", summary: "Se cuenta hasta tres.", tags: [] };
  test("el título sale del resumen; si no hay, de lo que se dijo; y si aún no hay texto, de cuándo se grabó", () => {
    expect(recordingTitle(resumen, "Probando", fecha("2026-10-08 00:18"), madrid)).toBe("Prueba numérica");
    expect(
      recordingTitle(null, "Probando, probando. Un, dos, tres, un, dos, tres y seguimos contando sin parar nunca", fecha("2026-10-08 00:18"), madrid),
    ).toBe("Probando, probando. Un, dos, tres, un, dos, tres y seguimos…");
    expect(recordingTitle(null, "  ", fecha("2026-10-08 00:18"), madrid)).toBe("Grabación del 8 de octubre de 2026, 00:18");
  });
  test("el extracto es la primera frase del resumen, o el principio de lo que se dijo", () => {
    const dos = { title: "T", summary: "Se cuenta hasta tres. Y luego nada.", tags: [] };
    expect(recordingExcerpt(dos, "Probando")).toBe("Se cuenta hasta tres.");
    expect(recordingExcerpt(null, "Probando, probando.\nUn, dos, tres.")).toBe("Probando, probando. Un, dos, tres.");
    expect(recordingExcerpt(null, null)).toBeNull();
  });
  test("la fecha se dice como la diría una persona: hoy, ayer, el día, y el año solo si no es este", () => {
    const ahora = fecha("2026-10-08 01:30");
    expect(recordingWhen(fecha("2026-10-08 00:18"), ahora, madrid)).toBe("hoy, 00:18");
    expect(recordingWhen(fecha("2026-10-07 20:01"), ahora, madrid)).toBe("ayer, 20:01");
    expect(recordingWhen(fecha("2026-10-05 09:32"), ahora, madrid)).toBe("5 oct, 09:32");
    expect(recordingWhen(fecha("2025-08-15 23:50"), ahora, madrid)).toBe("15 ago 2025");
  });
  test("las etiquetas se enseñan hasta tres y el resto se cuenta", () => {
    expect(visibleTags(["a", "b"])).toEqual({ shown: ["a", "b"], hidden: 0 });
    expect(visibleTags(["a", "b", "c", "d", "e"])).toEqual({ shown: ["a", "b", "c"], hidden: 2 });
  });
});

describe("qué palabra suena en cada instante", () => {
  const transcript: Transcript = {
    text: "Hola, mundo\nBien.",
    segments: [
      { start: 0, end: 2, speaker: "Speaker 1", text: "Hola, mundo", words: [{ start: 0, end: 0.5, text: "Hola," }, { start: 0.9, end: 1.4, text: "mundo" }] },
      { start: 2.5, end: 4, speaker: "Speaker 2", text: "Bien.", words: [{ start: 2.6, end: 3, text: "Bien." }] },
    ],
  };
  test("en mitad de una palabra, esa palabra", () => {
    expect(playbackPosition(transcript, 0.2)).toEqual({ segment: 0, word: 0 });
    expect(playbackPosition(transcript, 3.5)).toEqual({ segment: 1, word: 0 });
  });
  test("en un silencio entre palabras, se queda la anterior", () => {
    expect(playbackPosition(transcript, 0.7)).toEqual({ segment: 0, word: 0 });
    expect(playbackPosition(transcript, 1.6)).toEqual({ segment: 0, word: 1 });
  });
  test("segmento empezado pero antes de su primera palabra: segmento sin palabra", () => {
    expect(playbackPosition(transcript, 2.55)).toEqual({ segment: 1, word: null });
  });
  test("antes del primer segmento no hay posición", () => {
    expect(playbackPosition(transcript, -1)).toBeNull();
  });
  test("pasado el final, la última palabra", () => {
    expect(playbackPosition(transcript, 10)).toEqual({ segment: 1, word: 0 });
  });
  test("un segmento sin palabras se señala entero", () => {
    const sinPalabras: Transcript = { text: "", segments: [{ start: 0, end: 3, speaker: "Speaker 1", text: "Hola" }, { start: 3, end: 6, speaker: "Speaker 2", text: "Adios" }] };
    expect(playbackPosition(sinPalabras, 4.2)).toEqual({ segment: 1, word: null });
  });
  test("una transcripción sin segmentos no tiene posiciones", () => {
    expect(playbackPosition({ text: "plano", segments: [] }, 1)).toBeNull();
  });
});

describe("textos de la biblioteca", () => {
  test("el resumen cuenta el total y, solo si hay, lo que falta por transcribir", () => {
    expect(librarySummary([])).toBe("0 en la biblioteca");
    expect(librarySummary(["done", "done"])).toBe("2 en la biblioteca");
    expect(librarySummary(["done", "pending", "failed"])).toBe("3 en la biblioteca, 2 sin transcribir");
  });
  test("borrar de un conector deja claro que la página se archiva y la biblioteca no se toca", () => {
    const texto = rowActionText.unpublish("notion");
    expect(texto).toContain("se archiva en Notion");
    expect(texto).toContain("se quedan en la biblioteca");
  });
  test("quitar el audio avisa distinto según exista o no el original", () => {
    expect(rowActionText.removeAudio(true)).toContain("el original en su carpeta se conserva");
    expect(rowActionText.removeAudio(false)).toContain("se pierde del todo");
  });
});

describe("la transcripción copiada", () => {
  test("con hablantes, un turno por cambio de hablante con su nombre delante", () => {
    const transcript: Transcript = { text: "", segments: [segment("Ana", 0, "Hola."), segment("Ana", 1, "¿Qué tal?"), segment("Luis", 2, "Bien.")] };
    expect(renderedTranscript(transcript)).toBe("Ana: Hola. ¿Qué tal?\nLuis: Bien.");
  });
  test("sin hablantes, el texto tal cual", () => {
    expect(renderedTranscript({ text: "uno\ndos", segments: [segment(null, 0, "uno"), segment(null, 1, "dos")] })).toBe("uno\ndos");
  });
});
