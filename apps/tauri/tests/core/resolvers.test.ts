import { describe, expect, test } from "vitest";
import { addableModels, addedModelProblem, defaultLocalStt, downloadLabel, llmProvider, nextResolverName, presetFor, remotePresets, remoteSection, removable, remoteURLProblem, resolverName, resolverProblem, resolversFooter, resolverSubtitle } from "../../src/core/resolvers";
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

describe("proveedores nativos de LLM", () => {
  test("los LLM ofrecen Anthropic, Google Gemini y Mistral con su API; los STT solo servicios compatibles", () => {
    const llm = remotePresets("llm");
    expect(llm.find((preset) => preset.name === "Anthropic")).toMatchObject({ provider: "anthropic", baseURL: "https://api.anthropic.com/v1" });
    expect(llm.find((preset) => preset.name === "Google Gemini")).toMatchObject({ provider: "google", baseURL: "https://generativelanguage.googleapis.com/v1beta" });
    expect(llm.find((preset) => preset.name === "Mistral")).toMatchObject({ provider: "mistral", baseURL: "https://api.mistral.ai/v1" });
    expect(remotePresets("stt").every((preset) => preset.provider === "openai-compatible")).toBe(true);
  });

  test("un resolutor guardado sin proveedor sigue siendo compatible con OpenAI", () => {
    expect(llmProvider({ role: "llm" })).toBe("openai-compatible");
    expect(llmProvider({ role: "llm", provider: "anthropic" })).toBe("anthropic");
    expect(() => llmProvider({ role: "llm", provider: "cohere" })).toThrow("Proveedor de resolutor no válido");
    expect(() => llmProvider({ role: "stt", provider: "anthropic" })).toThrow("Los STT remotos usan un servicio compatible con OpenAI");
    expect(llmProvider({ role: "stt", provider: "openai-compatible" })).toBe("openai-compatible");
  });

  test("la ficha nombra el servicio nativo y avisa de que necesita clave; los compatibles conservan su texto", () => {
    expect(remoteSection("llm", "anthropic", linux)).toEqual({
      header: "Anthropic",
      footer: "El texto de cada nota sale del equipo hacia Anthropic, con su propia API.",
      keyPlaceholder: "Obligatoria",
    });
    expect(remoteSection("llm", "openai-compatible").header).toBe("Servicio compatible con OpenAI");
    expect(remoteSection("llm", "openai-compatible").footer).toContain("Anthropic, Google Gemini y Mistral tienen su propia opción en Servicio.");
    expect(remoteSection("stt", "openai-compatible").footer).toContain("25 MB");
  });

  test("el servicio elegido se reconoce por proveedor y URL", () => {
    expect(presetFor("llm", "https://api.anthropic.com/v1", "anthropic")).toBe("Anthropic");
    expect(presetFor("llm", "https://proxy.empresa.es/v1", "anthropic")).toBe("Anthropic");
    expect(presetFor("llm", "https://api.mistral.ai/v1")).toBe("Otro servicio compatible");
    expect(presetFor("llm", "https://api.mistral.ai/v1", "mistral")).toBe("Mistral");
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

  test("el de serie se quita donde el catálogo permite volver a añadirlo; Apple Intelligence nunca", () => {
    expect(removable(base, catalog)).toBe(true);
    expect(removable(serie, catalog)).toBe(true);
    expect(removable(serie, null)).toBe(false);
    expect(removable({ ...serie, id: "remote", local: false }, null)).toBe(true);
    expect(removable({ id: "local-llm", local: true }, catalog)).toBe(false);
  });

  test("sin el de serie, el «+» vuelve a ofrecer su modelo", () => {
    expect(addableModels(catalog, [base]).map((entry) => entry.model)).toEqual(["large-v3-turbo", "tiny"]);
  });

  test("la receta que no elige usa el primer Whisper local que queda", () => {
    const remote = { id: "remote", name: "Groq", role: "stt" as const, local: false, enabled: true };
    expect(defaultLocalStt([remote, serie, base])?.id).toBe("local-stt");
    expect(defaultLocalStt([remote, base])?.id).toBe("local-stt-base");
    expect(defaultLocalStt([remote])).toBeUndefined();
    expect(resolversFooter("stt", linux, [remote, base])).toBe("Cada receta elige con qué transcribir, en Recetas. La que no elige usa Whisper · base.");
    expect(resolversFooter("stt", linux, [remote])).toBe("Cada receta elige con qué transcribir, en Recetas. La que no elige espera hasta que añadas un Whisper local.");
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
