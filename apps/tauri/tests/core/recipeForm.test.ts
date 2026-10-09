import { describe, expect, test } from "vitest";
import {
  maximumTextLines,
  recipeForm,
  recipeFormDefaults,
  recipeFormIssue,
  recipeFormIsVisible,
  recipeFormLoad,
  recipeFormNumberChoices,
  recipeFormNumberText,
  recipeFormOverrides,
  recipeFormSections,
  recipeFormValues,
  RecipeFormProblem,
  setting,
  valueAt,
  type FormField,
} from "../../src/core/recipeForm";

const esquema = `{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{
 "idioma":{"default":"es","title":"Idioma","description":"null = detectar","anyOf":[{"type":"string","enum":["es","en"]},{"type":"null"}]},
 "hablantes":{"title":"Hablantes","default":{},"type":"object","properties":{
   "detectar":{"default":false,"title":"Detectar hablantes","type":"boolean"},
   "cuantos":{"default":null,"title":"Cuántos","anyOf":[{"type":"integer","minimum":2,"maximum":6},{"type":"null"}]}}},
 "llm":{"default":"apple","title":"LLM","type":"string","enum":["apple","openai-1"]},
 "conectores":{"default":[],"type":"array","items":{"type":"string","enum":["notion","okf"]}},
 "nota":{"type":"string"},
 "umbral":{"default":0.5,"type":"number","minimum":0,"maximum":1},
 "obligatorio":{"type":"string"},
 "h2":{"default":{"a":true},"type":"object","properties":{"a":{"default":true,"type":"boolean"}}}},
"required":["obligatorio"]}`;

const formulario = (texto = esquema) => recipeForm(JSON.parse(texto));
const campo = (form: ReturnType<typeof formulario>, nombre: string) => form.fields.find((field) => field.name === nombre);
const subcampo = (form: ReturnType<typeof formulario>, grupo: string, nombre: string) => {
  const kind = campo(form, grupo)?.kind;
  return kind?.type === "group" ? kind.fields.find((field) => field.name === nombre) : undefined;
};
const field = (extra: Partial<FormField> & Pick<FormField, "name" | "kind">): FormField => ({
  label: extra.name,
  help: null,
  nullable: false,
  required: false,
  defaultValue: undefined,
  dependsOn: null,
  ...extra,
});
const problema = (texto: string) => {
  try {
    formulario(texto);
  } catch (failure) {
    return failure instanceof RecipeFormProblem ? [failure.reason, failure.path, failure.what] : String(failure);
  }
  return null;
};

describe("formulario de una receta de código: el esquema de Zod de buildRecipeForm", () => {
  test("lee cada campo con su título, su ayuda, su valor por defecto y si admite vacío, en el orden del script", () => {
    const leido = formulario();
    expect(leido.fields.map((item) => item.name)).toEqual(["idioma", "hablantes", "llm", "conectores", "nota", "umbral", "obligatorio", "h2"]);
    expect(campo(leido, "idioma")).toEqual(
      field({ name: "idioma", label: "Idioma", help: "null = detectar", kind: { type: "choice", options: [{ value: "es", label: "es" }, { value: "en", label: "en" }] }, nullable: true, defaultValue: "es" }),
    );
    expect(campo(leido, "hablantes")).toEqual(
      field({
        name: "hablantes",
        label: "Hablantes",
        kind: {
          type: "group",
          fields: [
            field({ name: "detectar", label: "Detectar hablantes", kind: { type: "toggle" }, defaultValue: false }),
            field({ name: "cuantos", label: "Cuántos", kind: { type: "number", minimum: 2, maximum: 6, integer: true }, nullable: true, defaultValue: null }),
          ],
        },
        defaultValue: {},
      }),
    );
    expect(campo(leido, "conectores")?.kind).toEqual({ type: "choices", options: [{ value: "notion", label: "notion" }, { value: "okf", label: "okf" }] });
    expect(campo(leido, "nota")).toEqual(field({ name: "nota", kind: { type: "text", lines: 1 } }));
    expect(campo(leido, "umbral")?.kind).toEqual({ type: "number", minimum: 0, maximum: 1, integer: false });
    expect(campo(leido, "obligatorio")?.required).toBe(true);
    expect(campo(leido, "obligatorio")?.defaultValue).toBeUndefined();
  });

  test("un texto con .meta({ lineas }) es un cuadro de esas líneas, con un tope; sin ellas, de una", () => {
    const leido = formulario(`{"type":"object","properties":{
     "prompt":{"default":null,"title":"Prompt","lineas":6,"type":["string","null"]},
     "mucho":{"type":"string","lineas":500},
     "raro":{"type":"string","lineas":"seis"},
     "corto":{"type":"string"}}}`);
    expect(campo(leido, "prompt")?.kind).toEqual({ type: "text", lines: 6 });
    expect(campo(leido, "prompt")?.nullable).toBe(true);
    expect(campo(leido, "mucho")?.kind).toEqual({ type: "text", lines: maximumTextLines });
    expect(campo(leido, "raro")?.kind).toEqual({ type: "text", lines: 1 });
    expect(campo(leido, "corto")?.kind).toEqual({ type: "text", lines: 1 });
  });

  test("un campo con .meta({ si }) depende de un interruptor de su mismo grupo y solo se ve si está encendido", () => {
    const leido = formulario(`{"type":"object","properties":{
     "resumir":{"type":"boolean","default":false},
     "prompt":{"type":["string","null"],"default":null,"si":"resumir","lineas":6},
     "hablantes":{"type":"object","default":{},"properties":{
       "detectar":{"type":"boolean","default":false},
       "cuantos":{"anyOf":[{"type":"integer","minimum":2,"maximum":6},{"type":"null"}],"default":null,"si":"detectar"}}}}}`);
    const prompt = campo(leido, "prompt")!;
    const cuantos = subcampo(leido, "hablantes", "cuantos")!;
    expect(prompt.dependsOn).toBe("resumir");
    expect(cuantos.dependsOn).toBe("detectar");
    const apagado = recipeFormDefaults(leido);
    const encendido = setting(setting(apagado, true, ["resumir"]), true, ["hablantes", "detectar"]);
    expect(recipeFormIsVisible(prompt, apagado, [])).toBe(false);
    expect(recipeFormIsVisible(prompt, encendido, [])).toBe(true);
    expect(recipeFormIsVisible(cuantos, apagado, ["hablantes"])).toBe(false);
    expect(recipeFormIsVisible(cuantos, encendido, ["hablantes"])).toBe(true);
    expect(recipeFormIsVisible(campo(leido, "resumir")!, apagado, [])).toBe(true);
  });

  test("un «si» que no apunta a un interruptor de su mismo grupo se dice con su camino", () => {
    const casos: [string, string][] = [
      ['{"type":"object","properties":{"a":{"type":"string","si":"falta"}}}', "a"],
      ['{"type":"object","properties":{"t":{"type":"string"},"a":{"type":"string","si":"t"}}}', "a"],
      ['{"type":"object","properties":{"b":{"type":"boolean"},"g":{"type":"object","properties":{"a":{"type":"string","si":"b"}}}}}', "g.a"],
    ];
    for (const [texto, camino] of casos) expect(problema(texto)).toEqual(["unsupported", camino, "un «si» que no es un interruptor de su mismo grupo"]);
  });

  test("una unión de literales con título se ve con sus nombres, y una constante es una opción fija", () => {
    const leido = formulario(`{"type":"object","properties":{
     "llm":{"default":"apple","title":"LLM","anyOf":[{"type":"string","const":"apple","title":"Apple"},{"type":"string","const":"o1","title":"OpenAI"}]},
     "uno":{"type":"string","const":"solo"},
     "conector":{"default":null,"anyOf":[{"anyOf":[{"type":"string","const":"K1","title":"Notion"}]},{"type":"null"}]},
     "ninguno":{"default":null,"anyOf":[{"anyOf":[]},{"type":"null"}]}},"required":["uno"]}`);
    expect(campo(leido, "llm")?.kind).toEqual({ type: "choice", options: [{ value: "apple", label: "Apple" }, { value: "o1", label: "OpenAI" }] });
    expect(campo(leido, "uno")?.kind).toEqual({ type: "choice", options: [{ value: "solo", label: "solo" }] });
    expect(campo(leido, "conector")?.kind).toEqual({ type: "choice", options: [{ value: "K1", label: "Notion" }] });
    expect(campo(leido, "conector")?.nullable).toBe(true);
    expect(campo(leido, "ninguno")?.kind).toEqual({ type: "choice", options: [] });
    expect(campo(leido, "ninguno")?.nullable).toBe(true);
  });

  test("un enumerado vacío, como los conectores cuando no hay ninguno, es un desplegable sin opciones", () => {
    const leido = formulario('{"type":"object","properties":{"conector":{"not":{}},"otro":{"anyOf":[]},"varios":{"type":"array","items":{"not":{}}}}}');
    expect(campo(leido, "conector")?.kind).toEqual({ type: "choice", options: [] });
    expect(campo(leido, "otro")?.kind).toEqual({ type: "choice", options: [] });
    expect(campo(leido, "varios")?.kind).toEqual({ type: "choices", options: [] });
  });

  test("lo que el formulario no sabe pintar se dice con su camino", () => {
    expect(problema('{"type":"string"}')).toEqual(["notAnObject", "", ""]);
    expect(problema('{"anyOf":[{"type":"object","properties":{}},{"type":"null"}]}')).toEqual(["notAnObject", "", ""]);
    expect(problema('{"type":"object","properties":{"extra":{"type":"object","additionalProperties":{"type":"string"}}}}')).toEqual([
      "unsupported",
      "extra",
      "un registro de claves libres (z.record)",
    ]);
    expect(problema('{"type":"object","properties":{"g":{"type":"object","properties":{"tareas":{"type":"array","items":{"type":"string"}}}}}}')).toEqual([
      "unsupported",
      "g.tareas",
      "una lista que no es de opciones (z.array de z.enum)",
    ]);
    expect(problema('{"type":"object","properties":{"x":{"anyOf":[{"type":"string"},{"type":"number"}]}}}')).toEqual(["unsupported", "x", "una unión de tipos distintos"]);
    expect(problema('{"type":"object","properties":{"x":{"$ref":"#"}}}')).toEqual(["unsupported", "x", "un esquema recursivo ($ref)"]);
    expect(problema('{"type":"object","properties":{"x":{"type":"array","prefixItems":[{"type":"string"}]}}}')).toEqual(["unsupported", "x", "una tupla (z.tuple)"]);
  });

  test("los valores son los del script con lo guardado encima, también dentro de los grupos", () => {
    const leido = formulario();
    const valores = recipeFormValues(leido, JSON.parse('{"hablantes":{"cuantos":3},"llm":"openai-1","quitado":1}'));
    expect(valores).toEqual(JSON.parse('{"idioma":"es","hablantes":{"detectar":false,"cuantos":3},"llm":"openai-1","conectores":[],"umbral":0.5,"h2":{"a":true}}'));
    expect(recipeFormValues(leido, undefined)).toEqual(recipeFormDefaults(leido));
  });

  test("se guarda solo lo que difiere del script, y volver al valor del script lo borra", () => {
    const leido = formulario();
    const porDefecto = recipeFormDefaults(leido);
    expect(recipeFormOverrides(leido, porDefecto)).toBeNull();
    const cambiados = setting(setting(setting(porDefecto, 3, ["hablantes", "cuantos"]), "en", ["idioma"]), "x", ["obligatorio"]);
    expect(recipeFormOverrides(leido, cambiados)).toEqual(JSON.parse('{"idioma":"en","hablantes":{"cuantos":3},"obligatorio":"x"}'));
    const deVuelta = setting(setting(cambiados, "es", ["idioma"]), undefined, ["obligatorio"]);
    expect(recipeFormOverrides(leido, deVuelta)).toEqual(JSON.parse('{"hablantes":{"cuantos":3}}'));
  });

  test("un grupo obligatorio sin valor por defecto se guarda vacío para que Zod rellene sus campos", () => {
    const leido = formulario('{"type":"object","properties":{"g":{"type":"object","properties":{"a":{"default":true,"type":"boolean"}}}},"required":["g"]}');
    expect(recipeFormOverrides(leido, recipeFormDefaults(leido))).toEqual({ g: {} });
  });

  test("lo guardado que ya no casa con el script se avisa en su campo", () => {
    const leido = formulario();
    const llm = campo(leido, "llm")!;
    const cuantos = subcampo(leido, "hablantes", "cuantos")!;
    const conectores = campo(leido, "conectores")!;
    expect(recipeFormIssue(llm, "viejo")).toBe("«viejo» ya no está entre las opciones");
    expect(recipeFormIssue(llm, "apple")).toBeNull();
    expect(recipeFormIssue(cuantos, 9)).toBe("tiene que estar entre 2 y 6");
    expect(recipeFormIssue(cuantos, 2.5)).toBe("tiene que ser un número entero");
    expect(recipeFormIssue(cuantos, null)).toBeNull();
    expect(recipeFormIssue(conectores, ["notion", "borrado"])).toBe("«borrado» ya no está entre las opciones");
    expect(recipeFormIssue(campo(leido, "obligatorio")!, undefined)).toBe("falta un valor");
    expect(recipeFormIssue(campo(leido, "nota")!, undefined)).toBeNull();
  });

  test("cambiar o quitar un valor por su camino crea los grupos que falten y no toca lo demás", () => {
    const valores = JSON.parse('{"a":1,"g":{"b":true}}');
    expect(setting(valores, "x", ["g", "c"])).toEqual(JSON.parse('{"a":1,"g":{"b":true,"c":"x"}}'));
    expect(setting(valores, 2, ["a"])).toEqual(JSON.parse('{"a":2,"g":{"b":true}}'));
    expect(setting(valores, undefined, ["g", "b"])).toEqual(JSON.parse('{"a":1,"g":{}}'));
    expect(setting(valores, false, ["n", "m"])).toEqual(JSON.parse('{"a":1,"g":{"b":true},"n":{"m":false}}'));
    expect(valueAt(valores, ["g", "b"])).toBe(true);
    expect(valueAt(valores, ["g", "z"])).toBeUndefined();
  });

  test("lo que devuelve buildRecipeForm se lee como sin formulario, un formulario o un problema que se enseña", () => {
    expect(recipeFormLoad(null)).toEqual({ kind: "noForm" });
    expect(recipeFormLoad(esquema)).toEqual({ kind: "form", form: formulario() });
    expect(recipeFormLoad('{"type":"string"}')).toEqual({ kind: "problem", problem: "buildRecipeForm tiene que devolver un objeto: z.object({ … })" });
    expect(recipeFormLoad("{").kind).toBe("problem");
  });

  test("las secciones siguen el orden del script: cada grupo con su camino y su título, y los campos sueltos de seguido juntos", () => {
    const leido = formulario(`{"type":"object","properties":{
     "a":{"type":"boolean"},
     "g":{"title":"Hablantes","type":"object","properties":{
       "b":{"type":"boolean"},
       "h":{"title":"Avanzado","type":"object","properties":{"c":{"type":"string"}}}}},
     "d":{"type":"string"}}}`);
    const secciones = recipeFormSections(leido);
    expect(secciones.map((item) => item.path)).toEqual([[], ["g"], ["g", "h"], []]);
    expect(secciones.map((item) => item.title)).toEqual([null, "Hablantes", "Hablantes · Avanzado", null]);
    expect(secciones.map((item) => item.fields.map((candidate) => candidate.name))).toEqual([["a"], ["b"], ["c"], ["d"]]);
  });

  test("un entero con mínimo y máximo cercanos se elige de una lista; un rango absurdo o enorme, no", () => {
    const entero = (minimo: number, maximo: number) => field({ name: "n", kind: { type: "number", minimum: minimo, maximum: maximo, integer: true } });
    expect(recipeFormNumberChoices(entero(2, 6))).toEqual([2, 3, 4, 5, 6]);
    expect(recipeFormNumberChoices(entero(1.5, 4.5))).toEqual([2, 3, 4]);
    expect(recipeFormNumberChoices(entero(6, 2))).toBeNull();
    expect(recipeFormNumberChoices(entero(0, 100))).toBeNull();
    expect(recipeFormNumberChoices(entero(1e20, 1e20 + 5))).toBeNull();
    expect(recipeFormNumberChoices(field({ name: "n", kind: { type: "number", minimum: 2, maximum: 6, integer: false } }))).toBeNull();
    expect(recipeFormNumberText(1e20)).toBe("1e+20");
    expect(recipeFormNumberText(3)).toBe("3");
  });
});
