import { describe, expect, test } from "vitest";
import { addableModels, addedModelProblem, downloadLabel, nextResolverName, presetFor, removable, remoteURLProblem, resolverName, resolverProblem, resolverSubtitle } from "../../src/core/resolvers";
import { macOS } from "../../src/core/platform";
import { linux } from "./platforms";

describe("resolutores como en la app Swift", () => {
  test("la URL de un servicio se valida igual que en Swift", () => {
    expect(remoteURLProblem("")).toBe("Escribe la URL de la API.");
    expect(remoteURLProblem("api.openai.com/v1")).toBe("La URL tiene que empezar por http:// o https://.");
    expect(remoteURLProblem("https://u:p@api.openai.com/v1")).toBe("La URL no puede llevar usuario, contraseña ni parámetros.");
    expect(remoteURLProblem("https://api.openai.com/v1?x=1")).toBe("La URL no puede llevar usuario, contraseña ni parámetros.");
    expect(remoteURLProblem("http://api.example.com/v1")).toBe("Usa https:// para un servicio fuera de tu red.");
    expect(remoteURLProblem("http://192.168.1.20:1234/v1")).toBeNull();
    expect(remoteURLProblem("http://100.101.102.103:11434/v1")).toBeNull();
    expect(remoteURLProblem("https://api.openai.com/v1")).toBeNull();
  });
  test("un remoto sin modelo está sin terminar de configurar y el local depende de su motor", () => {
    expect(resolverProblem({ local: false, url: "https://api.openai.com/v1", model: " " }, null)).toBe("Elige el modelo.");
    expect(resolverProblem({ local: true }, "el modelo de Whisper no está descargado; descárgalo aquí abajo")).toContain("Whisper");
    expect(resolverProblem({ local: false, url: "https://api.openai.com/v1", model: "gpt-4o-mini" }, null)).toBeNull();
  });
  test("la fila dice dónde corre y con qué modelo", () => {
    const remoto = { id: "r", name: "Groq", role: "stt" as const, local: false, enabled: true, url: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo" };
    expect(resolverSubtitle(remoto, null)).toBe("api.groq.com · whisper-large-v3-turbo");
    expect(resolverSubtitle({ ...remoto, model: "" }, "Elige el modelo.")).toBe("Sin terminar de configurar");
    expect(resolverSubtitle({ ...remoto, local: true }, null)).toBe("En este Mac");
  });
  test("los nombres nuevos no se repiten y el servicio se reconoce por su URL", () => {
    expect(nextResolverName("OpenAI", ["OpenAI", "OpenAI 2"])).toBe("OpenAI 3");
    expect(nextResolverName("Groq", ["OpenAI"])).toBe("Groq");
    expect(presetFor("llm", "http://localhost:11434/v1")).toBe("Ollama");
    expect(presetFor("llm", "https://mi.servidor/v1")).toBe("Otro servicio compatible");
  });
});

describe("modelos de Whisper local", () => {
  const catalog = {
    default: "large-v3-turbo",
    models: [
      { model: "large-v3-turbo", label: "large-v3-turbo", bytes: 1_620_000_000, installed: true },
      { model: "tiny", label: "tiny", bytes: 78_000_000, installed: false },
      { model: "base", label: "base", bytes: 148_000_000, installed: true },
    ],
  };
  const serie = { id: "local-stt", name: "Whisper · en este equipo", role: "stt" as const, local: true, enabled: true };
  const base = { id: "local-stt-base", name: "Whisper · base", role: "stt" as const, local: true, enabled: true, model: "base" };

  test("el «+» ofrece los modelos que faltan, sin el de serie, con su tamaño", () => {
    expect(addableModels(catalog, [serie, base])).toEqual([{ model: "tiny", title: "Whisper · tiny (unos 78 MB)" }]);
    expect(addableModels(null, [serie])).toEqual([]);
  });

  test("un modelo añadido se llama por su modelo y dice dónde corre", () => {
    expect(resolverName(base, "stt", linux)).toBe("Whisper · base");
    expect(resolverName(serie, "stt", linux)).toBe("Whisper · en este equipo");
    expect(resolverSubtitle(base, null, linux)).toBe("En este equipo · base");
    expect(resolverSubtitle(serie, null, linux)).toBe("En este equipo");
  });

  test("solo los modelos añadidos se pueden quitar", () => {
    expect(removable(base)).toBe(true);
    expect(removable(serie)).toBe(false);
    expect(removable({ ...serie, id: "remote", local: false })).toBe(true);
  });

  test("descargar dice el tamaño de ese modelo; sin catálogo, el del modelo de serie del sistema", () => {
    expect(downloadLabel("tiny", catalog, linux)).toBe("Descargar (unos 78 MB)");
    expect(downloadLabel("large-v3-turbo", catalog, linux)).toBe("Descargar (unos 1,6 GB)");
    expect(downloadLabel("openai_whisper-large-v3-v20240930", null, macOS)).toBe("Descargar (unos 3 GB)");
  });

  test("un modelo añadido sin descargar lo dice en su fila", () => {
    expect(addedModelProblem(base, catalog)).toBeNull();
    expect(addedModelProblem({ ...base, id: "local-stt-tiny", model: "tiny" }, catalog)).toBe("el modelo no está descargado; descárgalo aquí abajo");
    expect(addedModelProblem(base, null)).toBeNull();
  });
});
