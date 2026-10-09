import { describe, expect, test } from "vitest";
import { nextResolverName, presetFor, remoteURLProblem, resolverProblem, resolverSubtitle } from "../../src/core/resolvers";

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
