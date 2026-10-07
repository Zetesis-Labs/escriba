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
    const nota = await escriba.transcribir(audio);
    await nota.resumir();
    await nota.guardar();
    for (const conector of escriba.conectores) {
      try {
        await escriba.conector(conector.clave).publicar(nota);
      } catch (error) {
        escriba.log(`no se pudo publicar en ${conector.nombre}: ${error}`);
      }
    }
  }
  return __toCommonJS(receta_exports);
})();
"""##,
        fingerprint: "e17525f17052d362")
}
