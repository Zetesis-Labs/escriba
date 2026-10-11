/// <reference path="../../../../recetas/escriba-recetas.d.ts" />
import type { z } from "zod";
export type Lists = ListasDeEscriba;
export function withDefaultLanguage(form: unknown, defaultLanguage: unknown = "es"): unknown {
  const schema = form as z.ZodObject<z.ZodRawShape>;
  const idioma = schema.shape?.idioma as z.ZodDefault<z.ZodType> | undefined;
  if (!idioma) return form;
  const language =
    defaultLanguage === null || defaultLanguage === "auto"
      ? null
      : defaultLanguage === "en"
        ? "en"
        : "es";
  return schema.extend({
    idioma: idioma.unwrap().default(language).meta(idioma.meta() || {}),
  });
}
