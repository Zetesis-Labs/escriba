/// <reference path="../../../../recetas/escriba-recetas.d.ts" />
import { buildRecipeForm } from "../../../../recetas/por-defecto/receta";
export type Lists = ListasDeEscriba;
export function defaultRecipeForm(
  lists: Lists,
  defaultLanguage: unknown = "es",
) {
  const form = buildRecipeForm(lists);
  const language =
    defaultLanguage === null || defaultLanguage === "auto"
      ? null
      : defaultLanguage === "en"
        ? "en"
        : "es";
  return form.extend({
    idioma: form.shape.idioma
      .unwrap()
      .default(language)
      .meta(form.shape.idioma.meta() || {}),
  });
}
