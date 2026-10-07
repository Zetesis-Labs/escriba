import EscribaEngine

extension RecipePackage {
    public static let defaultRecipe = RecipePackage(
        key: "por-defecto",
        source: ##"""
"use strict";
var __receta = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // recetas/por-defecto/receta.ts
  var receta_exports = {};
  __export(receta_exports, {
    flujo: () => flujo,
    receta: () => receta
  });
  var receta = { nombre: "Por defecto" };
  async function flujo(audio, escriba) {
    const parametros = escriba.parametros;
    if (!parametros) throw new Error("la receta por defecto necesita los parámetros de su formulario");
    const nota = await escriba.transcribir(audio, {
      stt: parametros.stt,
      idioma: parametros.idioma,
      hablantes: parametros.hablantes
    });
    if (parametros.resumir) await nota.resumir({ llm: parametros.llm, prompt: parametros.prompt });
    await nota.guardar();
    for (const clave of parametros.conectores) {
      try {
        await escriba.conector(clave).publicar(nota);
      } catch (error) {
        escriba.log(`no se pudo publicar en ${clave}: ${error}`);
      }
    }
  }
  return __toCommonJS(receta_exports);
})();
"""##,
        fingerprint: "f16c41caf9b723ad")
}
